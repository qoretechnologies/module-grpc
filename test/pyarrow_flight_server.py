#!/usr/bin/env python3
"""
PyArrow Flight server for interoperability testing with Qore ArrowFlightClient.

Provides test datasets matching the Qore arrow-flight.qtest structure:
  - "sales": 3-row dataset with id/product/amount columns (DoGet)
  - "writable": accepts DoPut writes
  - "transform": DoExchange that doubles input values
  - health_check / echo actions

Binds to a dynamic port and prints PORT:<n> on stdout for the Qore test
to parse and connect to.

Copyright (C) 2026 Qore Technologies, s.r.o., all rights reserved
"""

import sys
import pyarrow as pa
import pyarrow.flight as flight


class InteropFlightServer(flight.FlightServerBase):
    def __init__(self, location, **kwargs):
        super().__init__(location, **kwargs)

        # Sales dataset
        self.sales_schema = pa.schema([
            pa.field("id", pa.int64()),
            pa.field("product", pa.utf8()),
            pa.field("amount", pa.float64()),
        ])
        self.sales_data = pa.table(
            {
                "id": [1, 2, 3],
                "product": ["Widget", "Gadget", "Gizmo"],
                "amount": [9.99, 24.99, 14.50],
            },
            schema=self.sales_schema,
        )

        # Writable dataset
        self.writable_schema = pa.schema([
            pa.field("key", pa.utf8()),
            pa.field("value", pa.int64()),
        ])
        self.put_data = {}

        # Transform dataset (for DoExchange)
        self.transform_in_schema = pa.schema([pa.field("input", pa.int64())])
        self.transform_out_schema = pa.schema([pa.field("output", pa.int64())])

    # -- ListFlights ----------------------------------------------------------

    def list_flights(self, context, criteria):
        yield self._make_flight_info("sales")
        yield self._make_flight_info("writable")
        yield self._make_flight_info("transform")

    # -- GetFlightInfo --------------------------------------------------------

    def get_flight_info(self, context, descriptor):
        name = self._resolve_name(descriptor)
        return self._make_flight_info(name)

    # -- GetSchema ------------------------------------------------------------

    def get_schema(self, context, descriptor):
        name = self._resolve_name(descriptor)
        schema = self._schema_for(name)
        return flight.SchemaResult(schema)

    # -- DoGet ----------------------------------------------------------------

    def do_get(self, context, ticket):
        name = ticket.ticket.decode("utf-8")
        if name == "sales":
            return flight.RecordBatchStream(self.sales_data)
        if name == "writable":
            table = self.put_data.get(
                name,
                pa.table({"key": [], "value": []}, schema=self.writable_schema),
            )
            return flight.RecordBatchStream(table)
        raise flight.FlightServerError(f"dataset '{name}' not found")

    # -- DoPut ----------------------------------------------------------------

    def do_put(self, context, descriptor, reader, writer):
        name = self._resolve_name(descriptor)
        batches = []
        for chunk in reader:
            batches.append(chunk.data)
        self.put_data[name] = pa.Table.from_batches(batches, schema=reader.schema)
        writer.write_metadata(b"ok")

    # -- DoExchange -----------------------------------------------------------

    def do_exchange(self, context, descriptor, reader, writer):
        writer.begin(self.transform_out_schema)
        for chunk in reader:
            batch = chunk.data
            input_col = batch.column("input")
            output_vals = [v.as_py() * 2 for v in input_col]
            out_batch = pa.record_batch(
                {"output": output_vals}, schema=self.transform_out_schema
            )
            writer.write_batch(out_batch)

    # -- DoAction -------------------------------------------------------------

    def do_action(self, context, action):
        if action.type == "health_check":
            yield flight.Result(b"healthy")
        elif action.type == "echo":
            yield flight.Result(action.body.to_pybytes())
        else:
            raise flight.FlightServerError(f"action '{action.type}' not found")

    # -- ListActions ----------------------------------------------------------

    def list_actions(self, context):
        return [
            ("health_check", "Check server health"),
            ("echo", "Echo the input"),
        ]

    # -- helpers --------------------------------------------------------------

    def _resolve_name(self, descriptor):
        if descriptor.descriptor_type == flight.DescriptorType.PATH:
            p = descriptor.path[0]
            return p.decode("utf-8") if isinstance(p, bytes) else p
        if descriptor.descriptor_type == flight.DescriptorType.CMD:
            return descriptor.command.decode("utf-8")
        raise flight.FlightServerError("invalid descriptor type")

    def _schema_for(self, name):
        if name == "sales":
            return self.sales_schema
        if name == "writable":
            return self.writable_schema
        if name == "transform":
            return self.transform_in_schema
        raise flight.FlightServerError(f"dataset '{name}' not found")

    def _make_flight_info(self, name):
        schema = self._schema_for(name)
        descriptor = flight.FlightDescriptor.for_path(name)
        total = self.sales_data.num_rows if name == "sales" else -1
        endpoints = [flight.FlightEndpoint(flight.Ticket(name.encode("utf-8")), [])]
        return flight.FlightInfo(schema, descriptor, endpoints, total, -1)


if __name__ == "__main__":
    server = InteropFlightServer("grpc://0.0.0.0:0")
    # Print the port so the Qore test can connect
    print(f"PORT:{server.port}", flush=True)
    server.serve()
