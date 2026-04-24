# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightDataProvider.qc Root data provider for Arrow Flight services

/*  ArrowFlightDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

    Permission is hereby granted, free of charge, to any person obtaining a
    copy of this software and associated documentation files (the "Software"),
    to deal in the Software without restriction, including without limitation
    the rights to use, copy, modify, merge, publish, distribute, sublicense,
    and/or sell copies of the Software, and to permit persons to whom the
    Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in
    all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
    FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
    DEALINGS IN THE SOFTWARE.
*/

#! Contains all public definitions in the ArrowFlightDataProvider module
public namespace ArrowFlightDataProvider {

#! The main app name for action catalog registration
public const AppName = "ArrowFlight";

#! Root data provider for Arrow Flight services
/** Provides hierarchical access to Arrow Flight datasets via the data provider API.

    The provider hierarchy is:
    - ArrowFlightDataProvider (root -- connection + dataset discovery)
      - \<dataset_name\> (ArrowFlightDatasetDataProvider)
        - get (ArrowFlightMethodDataProvider -- DoGet)
        - put (ArrowFlightMethodDataProvider -- DoPut)
        - exchange (ArrowFlightMethodDataProvider -- DoExchange)

    @par Example
    @code{.py}
ArrowFlightDataProvider provider({"url": "http://localhost:8815"});
auto rows = provider.getChildProvider("sales").getChildProvider("get").doRequest(NOTHING);
    @endcode
*/
public class ArrowFlightDataProvider inherits AbstractDataProvider {
    public {
        #! Provider info
        const ProviderInfo = <DataProviderInfo>{
            "type": "ArrowFlightDataProvider",
            "supports_children": True,
            "constructor_options": ConstructorOptions,
            "children_can_support_apis": True,
            "children_can_support_observers": True,
        };

        #! Constructor options
        const ConstructorOptions = {
            "url": <DataProviderOptionInfo>{
                "display_name": "URL",
                "short_desc": "The Arrow Flight server URL",
                "type": AbstractDataProviderType::get(StringType),
                "desc": "The URL of the Arrow Flight server (e.g., `http://localhost:8815` "
                    "or `https://flight.example.com:443`)",
            },
            "timeout_ms": <DataProviderOptionInfo>{
                "display_name": "Timeout",
                "short_desc": "Default call timeout in milliseconds",
                "type": AbstractDataProviderType::get(SoftIntType),
                "desc": "The default timeout for Arrow Flight calls in milliseconds",
                "default_value": 30000,
            },
            "grpcchannel": <DataProviderOptionInfo>{
                "display_name": "gRPC Channel",
                "short_desc": "A pre-built GrpcChannel object",
                "type": AbstractDataProviderType::get(new Type("GrpcChannel"), NOTHING, {
                    DTT_ClientOnly: True,
                }),
                "desc": "A pre-built `GrpcChannel` object for connection pooling",
            },
        };
    }

    private {
        #! The Arrow Flight client
        ArrowFlightClient flight_client;

        #! The gRPC channel
        GrpcChannel channel;

        #! Default options for calls
        *hash<auto> default_opts;

        #! Cached flight info by dataset name
        hash<string, hash<auto>> flight_info_cache;

        #! Whether the flight info cache has been loaded
        bool cache_loaded = False;

        #! Mutex for cache initialization
        Mutex cache_mutex();

        #! Display name
        string display_name = "ArrowFlight";
    }

    #! Creates the root Arrow Flight data provider from constructor options
    /** @param options constructor options hash

        @throw CONSTRUCTOR-ERROR missing or invalid options
    */
    constructor(*hash<auto> options) {
        *hash<auto> copts = checkOptions("CONSTRUCTOR-ERROR", ConstructorOptions, options);

        # Build channel
        if (copts.grpcchannel) {
            channel = copts.grpcchannel;
        } else if (copts.url) {
            channel = new GrpcChannel(copts.url);
        } else {
            throw "CONSTRUCTOR-ERROR", "'url' or 'grpcchannel' must be provided";
        }

        # Store default options
        if (copts.timeout_ms) {
            default_opts.timeout_ms = copts.timeout_ms;
        }

        flight_client = new ArrowFlightClient(channel);

        if (copts.url) {
            display_name = sprintf("ArrowFlight %s", copts.url);
        }
    }

    #! Creates the root Arrow Flight data provider from a channel
    /** @param channel the gRPC channel
        @param default_opts default call options
    */
    constructor(GrpcChannel channel, *hash<auto> default_opts) {
        self.channel = channel;
        self.default_opts = default_opts;
        flight_client = new ArrowFlightClient(channel);
        display_name = sprintf("ArrowFlight %s", channel.target());
    }

    #! Returns the data provider name
    string getName() {
        return display_name;
    }

    #! Returns the data provider description
    *string getDesc() {
        return "Arrow Flight data provider for high-performance columnar data exchange";
    }

    #! Non-dataset child provider names
    const OperationChildren = ("list-flights", "get-flight-info", "do-action",
        "list-actions");

    #! Returns child provider names (dataset names + operation providers)
    private *list<string> getChildProviderNamesImpl() {
        ensureFlightInfoCache();
        return keys flight_info_cache + OperationChildren;
    }

    #! Returns a child provider by name (dataset or operation provider)
    /** Operation providers are returned directly without triggering a
        ListFlights RPC.  Dataset names are resolved via the flight info cache.
    */
    private *AbstractDataProvider getChildProviderImpl(string name) {
        switch (name) {
            case "list-flights":
                return new ArrowFlightListFlightsDataProvider(flight_client);
            case "get-flight-info":
                return new ArrowFlightGetFlightInfoDataProvider(flight_client);
            case "do-action":
                return new ArrowFlightDoActionDataProvider(flight_client);
            case "list-actions":
                return new ArrowFlightListActionsDataProvider(flight_client);
        }
        ensureFlightInfoCache();
        *hash<auto> info = flight_info_cache{name};
        if (info) {
            return new ArrowFlightDatasetDataProvider(flight_client, name, info,
                default_opts);
        }
    }

    #! Returns static provider info
    private hash<DataProviderInfo> getStaticInfoImpl() {
        return ProviderInfo;
    }

    #! Loads the flight info cache from ListFlights if not already loaded
    private ensureFlightInfoCache() {
        if (cache_loaded) {
            return;
        }
        AutoLock al(cache_mutex);
        if (cache_loaded) {
            return;
        }
        hash<string, hash<auto>> new_cache = {};
        list<hash<auto>> flights = flight_client.listFlights();
        for (int i = 0; i < flights.size(); ++i) {
            hash<auto> fi = flights[i];
            string name;
            if (fi.flight_descriptor.path) {
                name = fi.flight_descriptor.path[0];
            } else if (fi.flight_descriptor.cmd) {
                name = fi.flight_descriptor.cmd.toString("utf-8");
            } else {
                name = sprintf("flight-%d", i);
            }
            new_cache{name} = fi;
        }
        flight_info_cache = new_cache;
        cache_loaded = True;
    }
}

} # namespace ArrowFlightDataProvider
