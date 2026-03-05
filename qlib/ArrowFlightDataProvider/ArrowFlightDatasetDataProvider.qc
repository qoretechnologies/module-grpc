# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightDatasetDataProvider.qc Dataset-level data provider for Arrow Flight

/*  ArrowFlightDatasetDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Dataset-level data provider that contains method child providers
/** Each Arrow Flight dataset is represented by one instance of this class.
    Its children are the available operations: \c get, \c put, and \c exchange.

    @since ArrowFlightDataProvider 1.0
*/
public class ArrowFlightDatasetDataProvider inherits AbstractDataProvider {
    public {
        #! Provider info
        const ProviderInfo = <DataProviderInfo>{
            "type": "ArrowFlightDatasetDataProvider",
            "supports_children": True,
            "children_can_support_apis": True,
            "children_can_support_observers": True,
        };
    }

    private {
        #! The Arrow Flight client
        ArrowFlightClient flight_client;

        #! The dataset name
        string dataset_name;

        #! The FlightInfo for this dataset
        hash<auto> flight_info;

        #! Default options for calls
        *hash<auto> default_opts;
    }

    #! Creates the dataset data provider
    /** @param flight_client the Arrow Flight client
        @param dataset_name the dataset name
        @param flight_info the FlightInfo hash for this dataset
        @param default_opts default options for calls
    */
    constructor(ArrowFlightClient flight_client, string dataset_name,
            hash<auto> flight_info, *hash<auto> default_opts) {
        self.flight_client = flight_client;
        self.dataset_name = dataset_name;
        self.flight_info = flight_info;
        self.default_opts = default_opts;
    }

    #! Returns the data provider name
    string getName() {
        return dataset_name;
    }

    #! Returns the data provider description
    *string getDesc() {
        int total = flight_info.total_records ?? -1;
        if (total >= 0) {
            return sprintf("Arrow Flight dataset '%s' (%d records)", dataset_name, total);
        }
        return sprintf("Arrow Flight dataset '%s'", dataset_name);
    }

    #! Returns child provider names (get, put, exchange)
    private *list<string> getChildProviderNamesImpl() {
        return ("get", "put", "exchange");
    }

    #! Returns a child provider by name
    private *AbstractDataProvider getChildProviderImpl(string name) {
        switch (name) {
            case "get":
            case "put":
            case "exchange":
                return new ArrowFlightMethodDataProvider(
                    flight_client, dataset_name, flight_info, name, default_opts);
        }
    }

    #! Returns static provider info
    private hash<DataProviderInfo> getStaticInfoImpl() {
        return ProviderInfo;
    }
}

} # namespace ArrowFlightDataProvider
