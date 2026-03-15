#!/usr/bin/env python3
"""
PyArrow Flight client for interoperability testing with Qore ArrowFlightServer.

Connects to a Qore ArrowFlightServer and exercises all Flight RPCs, validating
the results.  Exits 0 on success, non-zero (with error details on stderr) on
failure.

Usage:  python3 pyarrow_flight_client.py <port>

Copyright (C) 2026 Qore Technologies, s.r.o., all rights reserved
"""

import sys
import traceback

import pyarrow as pa
import pyarrow.flight as flight


def main():
    if len(sys.argv) != 2:
        print("usage: pyarrow_flight_client.py <port>", file=sys.stderr)
        return 1

    port = int(sys.argv[1])
    client = flight.connect(f"grpc://localhost:{port}")

    errors = []

    def check(name, cond, msg=""):
        if not cond:
            detail = f"FAIL: {name}: {msg}" if msg else f"FAIL: {name}"
            errors.append(detail)
            print(detail, file=sys.stderr)
        else:
            print(f"  OK: {name}", file=sys.stderr)

    # ---- ListFlights --------------------------------------------------------
    try:
        flights = list(client.list_flights())
        check("ListFlights count", len(flights) >= 3,
              f"expected >= 3, got {len(flights)}")

        names = set()
        for fi in flights:
            if fi.descriptor.descriptor_type == flight.DescriptorType.PATH:
                p = fi.descriptor.path[0]
                names.add(p.decode("utf-8") if isinstance(p, bytes) else p)
        check("ListFlights has 'sales'", "sales" in names, f"names={names}")
    except Exception as e:
        errors.append(f"FAIL: ListFlights: {e}")
        traceback.print_exc(file=sys.stderr)

    # ---- GetFlightInfo ------------------------------------------------------
    try:
        desc = flight.FlightDescriptor.for_path("sales")
        info = client.get_flight_info(desc)
        check("GetFlightInfo total_records", info.total_records == 3,
              f"expected 3, got {info.total_records}")
        check("GetFlightInfo has schema", info.schema is not None)
    except Exception as e:
        errors.append(f"FAIL: GetFlightInfo: {e}")
        traceback.print_exc(file=sys.stderr)

    # ---- GetSchema ----------------------------------------------------------
    try:
        desc = flight.FlightDescriptor.for_path("sales")
        schema_result = client.get_schema(desc)
        schema = schema_result.schema
        check("GetSchema num_fields", len(schema) == 3,
              f"expected 3, got {len(schema)}")
        field_names = [f.name for f in schema]
        check("GetSchema field names",
              field_names == ["id", "product", "amount"],
              f"got {field_names}")
    except Exception as e:
        errors.append(f"FAIL: GetSchema: {e}")
        traceback.print_exc(file=sys.stderr)

    # ---- DoGet --------------------------------------------------------------
    try:
        ticket = flight.Ticket(b"sales")
        reader = client.do_get(ticket)
        table = reader.read_all()
        check("DoGet num_rows", table.num_rows == 3,
              f"expected 3, got {table.num_rows}")
        check("DoGet num_columns", table.num_columns == 3,
              f"expected 3, got {table.num_columns}")
        check("DoGet first product",
              table.column("product")[0].as_py() == "Widget",
              f"got {table.column('product')[0].as_py()}")
        check("DoGet second amount",
              table.column("amount")[1].as_py() == 24.99,
              f"got {table.column('amount')[1].as_py()}")
    except Exception as e:
        errors.append(f"FAIL: DoGet: {e}")
        traceback.print_exc(file=sys.stderr)

    # ---- DoPut --------------------------------------------------------------
    try:
        schema = pa.schema([
            pa.field("key", pa.utf8()),
            pa.field("value", pa.int64()),
        ])
        desc = flight.FlightDescriptor.for_path("writable")
        writer, reader = client.do_put(desc, schema)
        batch1 = pa.record_batch(
            {"key": ["a", "b"], "value": [1, 2]}, schema=schema
        )
        batch2 = pa.record_batch(
            {"key": ["c"], "value": [3]}, schema=schema
        )
        writer.write_batch(batch1)
        writer.write_batch(batch2)
        writer.close()
        check("DoPut completed", True)
    except Exception as e:
        errors.append(f"FAIL: DoPut: {e}")
        traceback.print_exc(file=sys.stderr)

    # ---- DoExchange ---------------------------------------------------------
    try:
        desc = flight.FlightDescriptor.for_path("transform")
        writer, reader = client.do_exchange(desc)
        in_schema = pa.schema([pa.field("input", pa.int64())])
        writer.begin(in_schema)
        in_batch = pa.record_batch({"input": [5, 10, 15]}, schema=in_schema)
        writer.write_batch(in_batch)
        writer.done_writing()

        table = reader.read_all()
        check("DoExchange num_rows", table.num_rows == 3,
              f"expected 3, got {table.num_rows}")
        out_col = table.column("output")
        expected = [10, 20, 30]
        actual = [out_col[i].as_py() for i in range(3)]
        check("DoExchange values", actual == expected,
              f"expected {expected}, got {actual}")
    except Exception as e:
        errors.append(f"FAIL: DoExchange: {e}")
        traceback.print_exc(file=sys.stderr)

    # ---- DoAction -----------------------------------------------------------
    try:
        action = flight.Action("health_check", b"")
        results = list(client.do_action(action))
        check("DoAction health_check count", len(results) == 1,
              f"expected 1, got {len(results)}")
        check("DoAction health_check body",
              results[0].body.to_pybytes() == b"healthy",
              f"got {results[0].body.to_pybytes()}")

        echo_data = b"hello flight interop"
        action2 = flight.Action("echo", echo_data)
        results2 = list(client.do_action(action2))
        check("DoAction echo", results2[0].body.to_pybytes() == echo_data,
              f"got {results2[0].body.to_pybytes()}")
    except Exception as e:
        errors.append(f"FAIL: DoAction: {e}")
        traceback.print_exc(file=sys.stderr)

    # ---- ListActions --------------------------------------------------------
    try:
        actions = list(client.list_actions())
        check("ListActions count", len(actions) >= 2,
              f"expected >= 2, got {len(actions)}")
        action_types = {a.type for a in actions}
        check("ListActions has health_check",
              "health_check" in action_types, f"types={action_types}")
        check("ListActions has echo",
              "echo" in action_types, f"types={action_types}")
    except Exception as e:
        errors.append(f"FAIL: ListActions: {e}")
        traceback.print_exc(file=sys.stderr)

    # ---- summary ------------------------------------------------------------
    if errors:
        print(f"\n{len(errors)} interop check(s) FAILED:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1

    print("All interop checks passed", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
