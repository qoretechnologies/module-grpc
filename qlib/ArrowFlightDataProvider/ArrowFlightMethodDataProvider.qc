# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightMethodDataProvider.qc Method-level data provider for Arrow Flight operations

/*  ArrowFlightMethodDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Bulk reader that preserves Arrow Flight record batches as columnar pipeline blocks
public class ArrowFlightColumnarBulkRecordInterface inherits AbstractDataProviderBulkRecordInterface {
    private {
        #! Dataset name, used in diagnostics
        string dataset_name;

        #! Active Flight stream reader
        ArrowFlightStreamReader reader;

        #! True after the Flight stream has been finished or cancelled
        bool finished = False;

        #! True when ColumnarResult bridge support is available in this grpc build
        bool columnar_supported;

        #! Record type metadata
        *hash<string, AbstractDataField> record_type;
    }

    #! Creates the bulk reader
    constructor(int block_size, ArrowFlightClient flight_client, string dataset_name,
            *binary ticket, *hash<auto> search_options, *hash<string, AbstractDataField> record_type)
            : AbstractDataProviderBulkRecordInterface(block_size, search_options.requires_result,
                search_options.max_records, search_options.limit) {
        self.dataset_name = dataset_name;
        self.record_type = record_type;
        columnar_supported = ArrowRecordBatch::supportsColumnarResult();
        reader = flight_client.doGet({"ticket": ticket ?? binary(dataset_name)});
    }

    destructor() {
        if (!finished) {
            reader.cancel();
        }
    }

    #! Returns the record description, if available
    *hash<string, AbstractDataField> getRecordType() {
        return record_type;
    }

    #! Returns the native bulk shape
    private DataProviderShape getValueShapeImpl() {
        return columnar_supported
            ? DataProviderShape::BufferColumns
            : DataProviderShape::HashOfLists;
    }

    #! Returns the next Flight batch in the most efficient supported shape
    private *auto getShapedValueImpl() {
        if (columnar_supported) {
            auto columns = reader.readColumnarResult();
            if (exists columns) {
                return columns;
            }
        } else {
            *ArrowRecordBatch batch = reader.read();
            if (batch) {
                return AbstractDataProcessor::recordsToHashList(batch.toRows());
            }
        }

        finishReader();
    }

    #! Compatibility implementation for consumers that call getValue()
    private *hash<auto> getValueImpl() {
        *auto value = getShapedValueImpl();
        if (!exists value) {
            return;
        }
        if (AbstractDataProcessor::isColumnarResult(value)) {
            return AbstractDataProcessor::bufferColumnsToHashList(value.toColumnHash());
        }
        if (AbstractDataProcessor::isHashOfBuffers(value)) {
            return AbstractDataProcessor::bufferColumnsToHashList(value);
        }
        return value;
    }

    #! Finishes the Flight stream and raises an informative error on failure
    private finishReader() {
        if (finished) {
            return;
        }
        finished = True;
        hash<GrpcCallResult> result = reader.finish();
        if (result.status_code != GRPC_STATUS_OK) {
            throw "ARROW-FLIGHT-ERROR",
                sprintf("DoGet failed for dataset '%s' with gRPC status %d: %s",
                    dataset_name, result.status_code, result.status_message);
        }
    }
}

#! Method-level data provider for Arrow Flight operations
/** Represents a single operation on an Arrow Flight dataset. Supports three operations:
    - @b get (DoGet): retrieve data as a list of row hashes
    - @b put (DoPut): send data as a list of row hashes
    - @b exchange (DoExchange): bidirectional data exchange
*/
public class ArrowFlightMethodDataProvider inherits AbstractDataProvider {
    public {
        #! Provider info
        const ProviderInfo = <DataProviderInfo>{
            "type": "ArrowFlightMethodDataProvider",
            "supports_request": True,
        };
    }

    private {
        #! The Arrow Flight client
        ArrowFlightClient flight_client;

        #! The dataset name
        string dataset_name;

        #! The FlightInfo for this dataset
        hash<auto> flight_info;

        #! The method type: "get", "put", or "exchange"
        string method_type;

        #! Default options for calls
        *hash<auto> default_opts;

        #! Cached request type
        *AbstractDataProviderType request_type;

        #! Cached response type
        *AbstractDataProviderType response_type;

        #! Cached Arrow schema (deserialized from flight_info.schema)
        *ArrowSchema cached_schema;
    }

    #! Creates the method data provider
    /** @param flight_client the Arrow Flight client
        @param dataset_name the dataset name
        @param flight_info the FlightInfo hash
        @param method_type the operation type: "get", "put", or "exchange"
        @param default_opts default options for calls
    */
    constructor(ArrowFlightClient flight_client, string dataset_name,
            hash<auto> flight_info, string method_type, *hash<auto> default_opts) {
        self.flight_client = flight_client;
        self.dataset_name = dataset_name;
        self.flight_info = flight_info;
        self.method_type = method_type;
        self.default_opts = default_opts;
    }

    #! Returns the data provider name
    string getName() {
        return method_type;
    }

    #! Returns the data provider description
    *string getDesc() {
        switch (method_type) {
            case "get":
                return sprintf("DoGet: retrieve data from dataset '%s'", dataset_name);
            case "put":
                return sprintf("DoPut: send data to dataset '%s'", dataset_name);
            case "exchange":
                return sprintf("DoExchange: bidirectional exchange on dataset '%s'",
                    dataset_name);
        }
    }

    #! Returns the request type for this method
    private *AbstractDataProviderType getRequestTypeImpl() {
        if (!request_type) {
            switch (method_type) {
                case "get": {
                    HashDataType req("ArrowFlightGetRequest");
                    req.addField(new QoreDataField("ticket",
                        "Flight ticket as binary data; defaults to dataset path if not "
                            "provided",
                        AbstractDataProviderType::get(SoftBinaryOrNothingType)));
                    req.addField(new QoreDataField("output_shape",
                        "Optional output shape: 'rows' returns one list of row hashes; "
                            "'columnar' returns a list of ColumnarResult record batches",
                        AbstractDataProviderType::get(SoftStringOrNothingType)));
                    request_type = req;
                    break;
                }
                case "put":
                case "exchange": {
                    string type_name = sprintf("ArrowFlight%sRequest",
                        method_type == "put" ? "Put" : "Exchange");
                    HashDataType req(type_name);
                    req.addField(new QoreDataField("rows",
                        "Rows or a columnar batch to send; accepts a row list, hash-of-lists, "
                            "ColumnarResult, DataFrame, or ArrowRecordBatch",
                        AbstractDataProviderType::get(AutoType)));
                    req.addField(new QoreDataField("output_shape",
                        "Optional output shape for exchange responses: 'rows' returns row hashes; "
                            "'columnar' returns ColumnarResult record batches",
                        AbstractDataProviderType::get(SoftStringOrNothingType)));
                    request_type = req;
                    break;
                }
            }
        }
        return request_type;
    }

    #! Returns the response type for this method
    private *AbstractDataProviderType getResponseTypeImpl() {
        if (!response_type) {
            switch (method_type) {
                case "get":
                case "exchange": {
                    *AbstractDataProviderType row_type = getRowType();
                    if (row_type) {
                        response_type = new SoftListDataType(
                            sprintf("%s_response", method_type), row_type);
                    } else {
                        response_type = AbstractDataProviderType::get(SoftListType);
                    }
                    break;
                }
                case "put": {
                    response_type = new HashDataType("ArrowFlightPutResponse");
                    break;
                }
            }
        }
        return response_type;
    }

    #! Makes the Arrow Flight call
    /** @param req the request data
        @param request_options additional request options

        @return the response data
    */
    private auto doRequestImpl(auto req, *hash<auto> request_options) {
        switch (method_type) {
            case "get":
                return doGetRequest(req);
            case "put":
                return doPutRequest(req);
            case "exchange":
                return doExchangeRequest(req);
        }
    }

    #! Returns static provider info
    private hash<DataProviderInfo> getStaticInfoImpl() {
        hash<DataProviderInfo> info = ProviderInfo;
        if (method_type == "get") {
            info.supports_read = True;
            info.supports_bulk_read = True;
            info.has_record = True;
        }
        if (method_type == "get" || method_type == "exchange") {
            info.supports_children = True;
            info.children_can_support_observers = True;
            if (method_type == "exchange") {
                info.children_can_support_messages = True;
            }
        }
        return info;
    }

    #! Returns child provider names
    /** DoGet and DoExchange methods expose an "events" child provider for observable
        support.
    */
    private *list<string> getChildProviderNamesImpl() {
        if (method_type == "get" || method_type == "exchange") {
            return ("events",);
        }
    }

    #! Returns a child provider by name
    private *AbstractDataProvider getChildProviderImpl(string name) {
        if (name == "events" && (method_type == "get" || method_type == "exchange")) {
            return new ArrowFlightStreamEventDataProvider(
                flight_client, dataset_name, flight_info, method_type, default_opts);
        }
    }

    #! Performs a DoGet call and returns all rows
    private auto doGetRequest(auto req) {
        hash<auto> ticket = {"ticket": req.ticket ?? binary(dataset_name)};
        ArrowFlightStreamReader reader = flight_client.doGet(ticket);
        on_error reader.cancel();

        if (wantsColumnarOutput(req)) {
            list<auto> all_batches = ();
            while (*auto columns = reader.readColumnarResult()) {
                push all_batches, columns;
            }
            checkReaderResult(reader);
            return all_batches;
        }

        list<hash<auto>> all_rows = ();
        while (*ArrowRecordBatch batch = reader.read()) {
            all_rows += batch.toRows();
        }
        checkReaderResult(reader);
        return all_rows;
    }

    #! Performs a DoPut call
    private hash<auto> doPutRequest(auto req) {
        ArrowSchema sch = getArrowSchema();
        hash<auto> descriptor = ArrowFlightHelper::pathDescriptor(dataset_name);
        ArrowFlightStreamWriter writer = flight_client.doPut(descriptor, sch);
        on_error writer.cancel();
        if (req.rows) {
            writer.write(req.rows);
        }
        writer.writesDone();
        hash<GrpcCallResult> result = writer.finish();
        if (result.status_code != GRPC_STATUS_OK) {
            throw "ARROW-FLIGHT-ERROR",
                sprintf("DoPut failed for dataset '%s' with gRPC status %d: %s",
                    dataset_name, result.status_code, result.status_message);
        }
        return result.body ?? {};
    }

    #! Performs a DoExchange call
    private auto doExchangeRequest(auto req) {
        hash<auto> descriptor = ArrowFlightHelper::pathDescriptor(dataset_name);
        ArrowSchema sch = getArrowSchema();
        ArrowFlightExchangeStream exchange = flight_client.doExchange(descriptor, sch);
        on_error exchange.cancel();
        # Write data if provided
        if (req.rows) {
            exchange.write(req.rows);
        }
        exchange.writesDone();

        if (wantsColumnarOutput(req)) {
            list<auto> all_batches = ();
            while (*auto columns = exchange.readColumnarResult()) {
                push all_batches, columns;
            }
            checkExchangeResult(exchange);
            return all_batches;
        }

        # Read all responses
        list<hash<auto>> all_rows = ();
        while (*ArrowRecordBatch batch = exchange.read()) {
            all_rows += batch.toRows();
        }
        checkExchangeResult(exchange);
        return all_rows;
    }

    #! Returns an iterator over Flight rows
    private AbstractDataProviderRecordIterator searchRecordsImpl(
            *hash<auto> where_cond, *hash<auto> search_options) {
        return searchRecordsBulkImpl(1000, where_cond, search_options).getRecordIterator();
    }

    #! Returns a bulk interface over Flight record batches
    private AbstractDataProviderBulkRecordInterface searchRecordsBulkImpl(int block_size = 1000,
            *hash<auto> where_cond, *hash<auto> search_options) {
        if (where_cond) {
            throw "UNSUPPORTED-SEARCH-ERROR",
                "Arrow Flight DoGet bulk reads do not support client-side where_cond filtering yet";
        }
        return new ArrowFlightColumnarBulkRecordInterface(block_size, flight_client, dataset_name,
            search_options.ticket, search_options, getRecordTypeImpl(search_options));
    }

    #! Returns the record type based on the Arrow schema
    private *hash<string, AbstractDataField> getRecordTypeImpl(*hash<auto> search_options) {
        if (!flight_info.schema) {
            return;
        }
        hash<string, AbstractDataField> fields;
        hash<auto> info = getArrowSchema().info();
        for (int i = 0; i < info.fields.size(); ++i) {
            hash<auto> field = info.fields[i];
            fields{field.name} = new QoreDataField(field.name,
                sprintf("Arrow field: %s", field.type),
                ArrowFlightTypeHelper::arrowTypeToDataType(field.type));
        }
        return fields;
    }

    #! Returns True if the request asks for ColumnarResult batches
    private bool wantsColumnarOutput(auto req) {
        return (req.output_shape ?? "rows") == "columnar";
    }

    #! Checks a DoGet result
    private checkReaderResult(ArrowFlightStreamReader reader) {
        hash<GrpcCallResult> result = reader.finish();
        if (result.status_code != GRPC_STATUS_OK) {
            throw "ARROW-FLIGHT-ERROR",
                sprintf("DoGet failed for dataset '%s' with gRPC status %d: %s",
                    dataset_name, result.status_code, result.status_message);
        }
    }

    #! Checks a DoExchange result
    private checkExchangeResult(ArrowFlightExchangeStream exchange) {
        hash<GrpcCallResult> result = exchange.finish();
        if (result.status_code != GRPC_STATUS_OK) {
            throw "ARROW-FLIGHT-ERROR",
                sprintf("DoExchange failed for dataset '%s' with gRPC status %d: %s",
                    dataset_name, result.status_code, result.status_message);
        }
    }

    #! Returns the deserialized ArrowSchema from flight_info
    private ArrowSchema getArrowSchema() {
        if (!cached_schema) {
            if (flight_info.schema) {
                cached_schema = new ArrowSchema(flight_info.schema);
            } else {
                throw "ARROW-FLIGHT-ERROR",
                    sprintf("no schema available for dataset '%s'", dataset_name);
            }
        }
        return cached_schema;
    }

    #! Returns the DataProvider row type based on the Arrow schema
    private *AbstractDataProviderType getRowType() {
        if (flight_info.schema) {
            try {
                ArrowSchema sch = new ArrowSchema(flight_info.schema);
                return ArrowFlightTypeHelper::schemaToDataType(sch,
                    dataset_name + "_row");
            } catch () {
                # Fall through to return NOTHING
            }
        }
    }
}

} # namespace ArrowFlightDataProvider
