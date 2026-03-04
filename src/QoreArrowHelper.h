/* -*- mode: c++; indent-tabs-mode: nil -*- */
/** @file QoreArrowHelper.h Arrow <-> Qore data conversion helpers */
/*
    Qore grpc module

    Copyright (C) 2026 Qore Technologies, s.r.o.

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

#ifndef _QORE_ARROW_HELPER_H
#define _QORE_ARROW_HELPER_H

#include <qore/Qore.h>

#include <arrow/api.h>
#include <arrow/ipc/api.h>

#include <memory>
#include <string>

//! Helper class for converting between Arrow data and Qore data structures
class QoreArrowHelper {
public:
    //! Convert an Arrow Array column to a Qore list
    /** @param array the Arrow array
        @param xsink exception sink
        @return a new QoreListNode with the array values, or nullptr on error
    */
    DLLLOCAL static QoreListNode* arrayToList(const std::shared_ptr<arrow::Array>& array,
        ExceptionSink* xsink);

    //! Build an Arrow Array from a Qore list
    /** @param type the Arrow data type
        @param list the Qore list of values
        @param xsink exception sink
        @return a new Arrow Array, or nullptr on error
    */
    DLLLOCAL static std::shared_ptr<arrow::Array> listToArray(
        const std::shared_ptr<arrow::DataType>& type,
        const QoreListNode* list, ExceptionSink* xsink);

    //! Convert an Arrow Schema to a Qore hash (ArrowSchemaInfo)
    /** @param schema the Arrow schema
        @param xsink exception sink
        @return a new QoreHashNode with schema info
    */
    DLLLOCAL static QoreHashNode* schemaToHash(const std::shared_ptr<arrow::Schema>& schema,
        ExceptionSink* xsink);

    //! Convert a Qore ArrowFieldInfo hash list to an Arrow Schema
    /** @param fields the Qore list of field info hashes
        @param metadata optional metadata hash
        @param xsink exception sink
        @return a new Arrow Schema, or nullptr on error
    */
    DLLLOCAL static std::shared_ptr<arrow::Schema> hashToSchema(
        const QoreListNode* fields, const QoreHashNode* metadata, ExceptionSink* xsink);

    //! Parse an Arrow data type name string to an Arrow DataType
    /** @param type_name the type name (e.g., "int32", "utf8", "timestamp[us, tz=UTC]")
        @param xsink exception sink
        @return the Arrow DataType, or nullptr on error
    */
    DLLLOCAL static std::shared_ptr<arrow::DataType> parseTypeName(const std::string& type_name,
        ExceptionSink* xsink);

    //! Get the string representation of an Arrow data type
    /** @param type the Arrow data type
        @return the type name string
    */
    DLLLOCAL static std::string typeName(const std::shared_ptr<arrow::DataType>& type);

    //! Build a field info hash (ArrowFieldInfo) from an Arrow field
    /** @param field the Arrow field
        @param xsink exception sink
        @return a new QoreHashNode with field info
    */
    DLLLOCAL static QoreHashNode* fieldToHash(const std::shared_ptr<arrow::Field>& field,
        ExceptionSink* xsink);

    //! Convert an Arrow KeyValueMetadata to a Qore hash
    /** @param metadata the Arrow metadata
        @param xsink exception sink
        @return a new QoreHashNode, or nullptr if metadata is null
    */
    DLLLOCAL static QoreHashNode* metadataToHash(
        const std::shared_ptr<const arrow::KeyValueMetadata>& metadata,
        ExceptionSink* xsink);

    //! Convert a Qore hash to Arrow KeyValueMetadata
    /** @param hash the Qore hash
        @return Arrow KeyValueMetadata, or nullptr if hash is null
    */
    DLLLOCAL static std::shared_ptr<arrow::KeyValueMetadata> hashToMetadata(
        const QoreHashNode* hash);

    //! Serialize a RecordBatch to IPC data_header + data_body pair
    /** @param batch the record batch
        @param xsink exception sink
        @return a hash with "data_header" (binary) and "data_body" (binary), or nullptr on error
    */
    DLLLOCAL static QoreHashNode* recordBatchToIpc(
        const std::shared_ptr<arrow::RecordBatch>& batch, ExceptionSink* xsink);

    //! Deserialize a RecordBatch from IPC data_header + data_body
    /** @param schema the Arrow schema
        @param data_header the IPC message header (flatbuffer)
        @param data_body the IPC message body (raw buffers)
        @param xsink exception sink
        @return a new RecordBatch, or nullptr on error
    */
    DLLLOCAL static std::shared_ptr<arrow::RecordBatch> ipcToRecordBatch(
        const std::shared_ptr<arrow::Schema>& schema,
        const BinaryNode* data_header, const BinaryNode* data_body,
        ExceptionSink* xsink);

    //! Serialize a Schema to IPC bytes
    /** @param schema the Arrow schema
        @param xsink exception sink
        @return a new BinaryNode with IPC-serialized schema, or nullptr on error
    */
    DLLLOCAL static BinaryNode* serializeSchema(
        const std::shared_ptr<arrow::Schema>& schema, ExceptionSink* xsink);

    //! Deserialize a Schema from IPC bytes
    /** @param data the IPC-serialized schema bytes
        @param xsink exception sink
        @return a new Arrow Schema, or nullptr on error
    */
    DLLLOCAL static std::shared_ptr<arrow::Schema> deserializeSchema(
        const BinaryNode* data, ExceptionSink* xsink);

private:
    //! Convert a single Arrow scalar value to a Qore value
    DLLLOCAL static QoreValue scalarToQore(const std::shared_ptr<arrow::Array>& array,
        int64_t index, ExceptionSink* xsink);

    //! Append a Qore value to an Arrow ArrayBuilder
    DLLLOCAL static bool appendToBuilder(arrow::ArrayBuilder* builder,
        const std::shared_ptr<arrow::DataType>& type,
        QoreValue val, ExceptionSink* xsink);

    //! Parse a child field from an ArrowFieldInfo hash
    DLLLOCAL static std::shared_ptr<arrow::Field> hashToField(
        const QoreHashNode* field_hash, ExceptionSink* xsink);
};

#endif // _QORE_ARROW_HELPER_H
