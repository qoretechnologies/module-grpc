# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightServer.qc High-level Arrow Flight server

/*  ArrowFlightServer.qc Copyright 2026 Qore Technologies, s.r.o.

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

public namespace Grpc {

#! High-level Arrow Flight server with dataset and action registration
/** Wraps a @ref GrpcServer with the Flight protocol schema and provides
    convenient dataset and action registration. The server dispatches
    incoming Flight RPCs to the appropriate registered handlers.

    @par Example:
    @code{.py}
ArrowFlightServer server();
server.registerDataset("sales", new SalesDataHandler());
server.registerAction("compact", "Compact storage",
    list<hash<auto>> sub(binary body) {
        # ... compact logic ...
        return ({"body": binary("done")},);
    });

int port = server.addInsecurePort("localhost:0");
server.start();
printf("Flight server on port %d\n", port);
server.wait();
    @endcode

    @since GrpcUtil 1.0
*/
public class ArrowFlightServer {
    private {
        #! The internal gRPC server
        GrpcServer m_server;

        #! Registered dataset handlers: name -> handler
        hash<string, ArrowFlightDatasetHandler> m_datasets;

        #! Registered action handlers: type -> handler code
        hash<string, code> m_actions;

        #! Registered action descriptions: type -> description
        hash<string, string> m_action_descs;

        #! Mutex for state
        Mutex m_mutex();
    }

    #! Create a new Arrow Flight server
    /** @param opts optional gRPC server options (max message size, etc.)

        @since %GrpcUtil 1.0
    */
    constructor(*hash<GrpcServerOptions> opts) {
        m_server = new GrpcServer(FlightProto::get(), opts);

        # Register Flight RPC handlers
        m_server.registerHandler("FlightService", "ListFlights",
            sub(hash<auto> request, GrpcServerStream stream,
                    hash<string, string> metadata) {
                handleListFlights(request, stream, metadata);
            });

        m_server.registerHandler("FlightService", "GetFlightInfo",
            hash<auto> sub(hash<auto> request, hash<string, string> metadata) {
                return handleGetFlightInfo(request, metadata);
            });

        m_server.registerHandler("FlightService", "PollFlightInfo",
            hash<auto> sub(hash<auto> request, hash<string, string> metadata) {
                return handlePollFlightInfo(request, metadata);
            });

        m_server.registerHandler("FlightService", "GetSchema",
            hash<auto> sub(hash<auto> request, hash<string, string> metadata) {
                return handleGetSchema(request, metadata);
            });

        m_server.registerHandler("FlightService", "DoGet",
            sub(hash<auto> request, GrpcServerStream stream,
                    hash<string, string> metadata) {
                handleDoGet(request, stream, metadata);
            });

        m_server.registerHandler("FlightService", "DoPut",
            hash<auto> sub(GrpcServerStream stream, hash<string, string> metadata) {
                return handleDoPut(stream, metadata);
            });

        m_server.registerHandler("FlightService", "DoExchange",
            sub(GrpcServerStream stream, hash<string, string> metadata) {
                handleDoExchange(stream, metadata);
            });

        m_server.registerHandler("FlightService", "DoAction",
            sub(hash<auto> request, GrpcServerStream stream,
                    hash<string, string> metadata) {
                handleDoAction(request, stream, metadata);
            });

        m_server.registerHandler("FlightService", "ListActions",
            sub(hash<auto> request, GrpcServerStream stream,
                    hash<string, string> metadata) {
                handleListActions(request, stream, metadata);
            });

        m_server.registerHandler("FlightService", "Handshake",
            sub(GrpcServerStream stream, hash<string, string> metadata) {
                handleHandshake(stream, metadata);
            });
    }

    #! Register a dataset handler
    /** @param name the dataset name (used as the first element of
        FlightDescriptor.path and as the Ticket)
        @param handler the dataset handler implementation

        @since %GrpcUtil 1.0
    */
    registerDataset(string name, ArrowFlightDatasetHandler handler) {
        AutoLock al(m_mutex);
        m_datasets{name} = handler;
    }

    #! Remove a registered dataset
    /** @param name the dataset name to remove

        @since %GrpcUtil 1.0
    */
    removeDataset(string name) {
        AutoLock al(m_mutex);
        remove m_datasets{name};
    }

    #! Register an action handler
    /** @param action_type the action type string
        @param description human-readable description of the action
        @param handler the action handler; receives the action body (binary)
        and returns a list of Result hashes

        @since %GrpcUtil 1.0
    */
    registerAction(string action_type, string description, code handler) {
        AutoLock al(m_mutex);
        m_actions{action_type} = handler;
        m_action_descs{action_type} = description;
    }

    #! Remove a registered action
    /** @param action_type the action type to remove

        @since %GrpcUtil 1.0
    */
    removeAction(string action_type) {
        AutoLock al(m_mutex);
        remove m_actions{action_type};
        remove m_action_descs{action_type};
    }

    #! Add an insecure (plaintext) listener
    /** @param addr the address to bind (e.g., "localhost:0")
        @return the port number bound

        @since %GrpcUtil 1.0
    */
    int addInsecurePort(string addr) {
        return m_server.addInsecurePort(addr);
    }

    #! Add a secure (TLS) listener
    /** @param addr the address to bind
        @param ssl SSL/TLS options
        @return the port number bound

        @since %GrpcUtil 1.0
    */
    int addSecurePort(string addr, hash<GrpcSslOptions> ssl) {
        return m_server.addSecurePort(addr, ssl);
    }

    #! Start the server
    /** @since %GrpcUtil 1.0
    */
    start() {
        m_server.start();
    }

    #! Wait for the server to shut down
    /** @since %GrpcUtil 1.0
    */
    wait() {
        m_server.wait();
    }

    #! Shut down the server gracefully
    /** @param timeout_ms optional shutdown timeout in milliseconds

        @since %GrpcUtil 1.0
    */
    shutdown(*int timeout_ms) {
        m_server.shutdown(timeout_ms);
    }

    #! Check if the server is running
    /** @return True if the server is running

        @since %GrpcUtil 1.0
    */
    bool isRunning() {
        return m_server.isRunning();
    }

    #! Get the underlying GrpcServer
    /** @return the internal GrpcServer

        @since %GrpcUtil 1.0
    */
    GrpcServer getGrpcServer() {
        return m_server;
    }

    # ---- Private Flight RPC handlers ----

    #! Resolve dataset name from FlightDescriptor
    private *string resolveDatasetName(hash<auto> descriptor) {
        if (descriptor.path && descriptor.path.size() > 0) {
            return descriptor.path[0];
        }
        if (descriptor.cmd) {
            if (descriptor.cmd.typeCode() == NT_BINARY) {
                return descriptor.cmd.toString("utf-8");
            }
            return string(descriptor.cmd);
        }
        return NOTHING;
    }

    #! Get a dataset handler, throwing NOT_FOUND if not registered
    private ArrowFlightDatasetHandler getDatasetHandler(string name) {
        AutoLock al(m_mutex);
        *ArrowFlightDatasetHandler handler = m_datasets{name};
        if (!handler) {
            throw "GRPC-NOT-FOUND", sprintf("dataset '%s' not found", name);
        }
        return handler;
    }

    private handleListFlights(hash<auto> request, GrpcServerStream stream,
            hash<string, string> metadata) {
        # Snapshot datasets under lock, iterate without lock
        hash<string, ArrowFlightDatasetHandler> datasets;
        {
            AutoLock al(m_mutex);
            datasets = m_datasets;
        }
        map (stream.write($1.value.getFlightInfo(
            ArrowFlightHelper::pathDescriptor($1.key)))),
            datasets.pairIterator();
    }

    private hash<auto> handleGetFlightInfo(hash<auto> request,
            hash<string, string> metadata) {
        *string name = resolveDatasetName(request);
        if (!name) {
            throw "GRPC-INVALID-ARGUMENT", "FlightDescriptor has no path or cmd";
        }
        ArrowFlightDatasetHandler handler = getDatasetHandler(name);
        return handler.getFlightInfo(request);
    }

    private hash<auto> handlePollFlightInfo(hash<auto> request,
            hash<string, string> metadata) {
        *string name = resolveDatasetName(request);
        if (!name) {
            throw "GRPC-INVALID-ARGUMENT", "FlightDescriptor has no path or cmd";
        }
        ArrowFlightDatasetHandler handler = getDatasetHandler(name);
        return {
            "info": handler.getFlightInfo(request),
            "flight_descriptor": request,
            "progress": 1.0,
        };
    }

    private hash<auto> handleGetSchema(hash<auto> request,
            hash<string, string> metadata) {
        *string name = resolveDatasetName(request);
        if (!name) {
            throw "GRPC-INVALID-ARGUMENT", "FlightDescriptor has no path or cmd";
        }
        ArrowFlightDatasetHandler handler = getDatasetHandler(name);
        ArrowSchema schema = handler.getSchema();
        return {
            "schema": ArrowIpc::writeSchema(schema),
        };
    }

    private handleDoGet(hash<auto> request, GrpcServerStream stream,
            hash<string, string> metadata) {
        # The ticket field contains the dataset identifier
        *string name;
        if (request.ticket) {
            if (request.ticket.typeCode() == NT_BINARY) {
                name = request.ticket.toString("utf-8");
            } else {
                name = string(request.ticket);
            }
        }
        if (!name) {
            throw "GRPC-INVALID-ARGUMENT", "Ticket has no ticket field";
        }
        ArrowFlightDatasetHandler handler = getDatasetHandler(name);
        handler.doGet(request, stream);
    }

    private hash<auto> handleDoPut(GrpcServerStream stream,
            hash<string, string> metadata) {
        # Read first message to get descriptor
        *hash<auto> first = stream.read(30s);
        if (!first) {
            throw "GRPC-INVALID-ARGUMENT", "DoPut: no initial FlightData received";
        }

        *string name;
        if (first.flight_descriptor) {
            name = resolveDatasetName(first.flight_descriptor);
        }
        if (!name) {
            throw "GRPC-INVALID-ARGUMENT",
                "DoPut: first FlightData has no flight_descriptor";
        }

        ArrowFlightDatasetHandler handler = getDatasetHandler(name);
        return handler.doPut(first.flight_descriptor, stream);
    }

    private handleDoExchange(GrpcServerStream stream,
            hash<string, string> metadata) {
        # Read first message to get descriptor
        *hash<auto> first = stream.read(30s);
        if (!first) {
            throw "GRPC-INVALID-ARGUMENT",
                "DoExchange: no initial FlightData received";
        }

        *string name;
        if (first.flight_descriptor) {
            name = resolveDatasetName(first.flight_descriptor);
        }
        if (!name) {
            throw "GRPC-INVALID-ARGUMENT",
                "DoExchange: first FlightData has no flight_descriptor";
        }

        ArrowFlightDatasetHandler handler = getDatasetHandler(name);
        handler.doExchange(first.flight_descriptor, stream);
    }

    private handleDoAction(hash<auto> request, GrpcServerStream stream,
            hash<string, string> metadata) {
        string action_type = request.type ?? "";

        code handler;
        {
            AutoLock al(m_mutex);
            *code h = m_actions{action_type};
            if (!h) {
                throw "GRPC-NOT-FOUND",
                    sprintf("action '%s' not registered", action_type);
            }
            handler = h;
        }

        list<hash<auto>> results = handler(request.body);
        for (int i = 0; i < results.size(); ++i) {
            stream.write(results[i]);
        }
    }

    private handleListActions(hash<auto> request, GrpcServerStream stream,
            hash<string, string> metadata) {
        # Snapshot action descriptions under lock, iterate without lock
        hash<string, string> descs;
        {
            AutoLock al(m_mutex);
            descs = m_action_descs;
        }
        map (stream.write({
            "type": $1.key,
            "description": $1.value,
        })), descs.pairIterator();
    }

    private handleHandshake(GrpcServerStream stream,
            hash<string, string> metadata) {
        # Default handshake: echo back the payload
        *hash<auto> request = stream.read(30s);
        if (request) {
            stream.write({
                "protocol_version": request.protocol_version ?? 0,
                "payload": request.payload ?? binary(),
            });
        }
    }
}

} # namespace Grpc
