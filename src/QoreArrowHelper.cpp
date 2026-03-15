/* -*- mode: c++; indent-tabs-mode: nil -*- */
/** @file QoreArrowHelper.cpp Arrow <-> Qore data conversion implementation */
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

#include "QoreArrowHelper.h"

#include <arrow/array.h>
#include <arrow/builder.h>
#include <arrow/type.h>
#include <arrow/io/memory.h>
#include <arrow/ipc/dictionary.h>
#include <arrow/ipc/reader.h>
#include <arrow/ipc/writer.h>
#include <arrow/util/decimal.h>
#include <arrow/util/float16.h>

#include <limits>
#include <sstream>
#include <stdexcept>

QoreValue QoreArrowHelper::scalarToQore(const std::shared_ptr<arrow::Array>& array,
        int64_t index, ExceptionSink* xsink) {
    if (array->IsNull(index)) {
        return QoreValue();
    }

    switch (array->type_id()) {
        case arrow::Type::BOOL:
            return std::static_pointer_cast<arrow::BooleanArray>(array)->Value(index);

        case arrow::Type::INT8:
            return (int64)std::static_pointer_cast<arrow::Int8Array>(array)->Value(index);
        case arrow::Type::INT16:
            return (int64)std::static_pointer_cast<arrow::Int16Array>(array)->Value(index);
        case arrow::Type::INT32:
            return (int64)std::static_pointer_cast<arrow::Int32Array>(array)->Value(index);
        case arrow::Type::INT64:
            return std::static_pointer_cast<arrow::Int64Array>(array)->Value(index);

        case arrow::Type::UINT8:
            return (int64)std::static_pointer_cast<arrow::UInt8Array>(array)->Value(index);
        case arrow::Type::UINT16:
            return (int64)std::static_pointer_cast<arrow::UInt16Array>(array)->Value(index);
        case arrow::Type::UINT32:
            return (int64)std::static_pointer_cast<arrow::UInt32Array>(array)->Value(index);
        case arrow::Type::UINT64: {
            uint64_t v = std::static_pointer_cast<arrow::UInt64Array>(array)->Value(index);
            if (v > (uint64_t)std::numeric_limits<int64_t>::max()) {
                return new QoreNumberNode(std::to_string(v).c_str());
            }
            return (int64)v;
        }

        case arrow::Type::HALF_FLOAT: {
            // half-float: convert raw uint16_t IEEE 754 bits to double via Float16
            uint16_t raw = std::static_pointer_cast<arrow::HalfFloatArray>(array)->Value(index);
            return (double)arrow::util::Float16::FromBits(raw).ToFloat();
        }
        case arrow::Type::FLOAT:
            return (double)std::static_pointer_cast<arrow::FloatArray>(array)->Value(index);
        case arrow::Type::DOUBLE:
            return std::static_pointer_cast<arrow::DoubleArray>(array)->Value(index);

        case arrow::Type::STRING: {
            auto str_array = std::static_pointer_cast<arrow::StringArray>(array);
            auto val = str_array->GetView(index);
            return new QoreStringNode(val.data(), val.size(), QCS_UTF8);
        }
        case arrow::Type::LARGE_STRING: {
            auto str_array = std::static_pointer_cast<arrow::LargeStringArray>(array);
            auto val = str_array->GetView(index);
            return new QoreStringNode(val.data(), val.size(), QCS_UTF8);
        }

        case arrow::Type::BINARY: {
            auto bin_array = std::static_pointer_cast<arrow::BinaryArray>(array);
            auto val = bin_array->GetView(index);
            SimpleRefHolder<BinaryNode> bin(new BinaryNode);
            bin->append(val.data(), val.size());
            return bin.release();
        }
        case arrow::Type::LARGE_BINARY: {
            auto bin_array = std::static_pointer_cast<arrow::LargeBinaryArray>(array);
            auto val = bin_array->GetView(index);
            SimpleRefHolder<BinaryNode> bin(new BinaryNode);
            bin->append(val.data(), val.size());
            return bin.release();
        }
        case arrow::Type::FIXED_SIZE_BINARY: {
            auto bin_array = std::static_pointer_cast<arrow::FixedSizeBinaryArray>(array);
            auto val = bin_array->GetView(index);
            SimpleRefHolder<BinaryNode> bin(new BinaryNode);
            bin->append(val.data(), val.size());
            return bin.release();
        }

        case arrow::Type::DATE32: {
            // days since Unix epoch
            auto date_array = std::static_pointer_cast<arrow::Date32Array>(array);
            int32_t days = date_array->Value(index);
            int64_t epoch_secs = static_cast<int64_t>(days) * 86400;
            return DateTimeNode::makeAbsolute(currentTZ(), epoch_secs, 0);
        }
        case arrow::Type::DATE64: {
            // milliseconds since Unix epoch
            auto date_array = std::static_pointer_cast<arrow::Date64Array>(array);
            int64_t ms = date_array->Value(index);
            return DateTimeNode::makeAbsolute(currentTZ(), ms / 1000, (ms % 1000) * 1000);
        }

        case arrow::Type::TIMESTAMP: {
            auto ts_array = std::static_pointer_cast<arrow::TimestampArray>(array);
            auto ts_type = std::static_pointer_cast<arrow::TimestampType>(array->type());
            int64_t val = ts_array->Value(index);

            const AbstractQoreZoneInfo* zone = currentTZ();
            if (!ts_type->timezone().empty()) {
                zone = find_create_timezone(ts_type->timezone().c_str(), xsink);
                if (*xsink) {
                    return QoreValue();
                }
            }

            int64_t secs = 0;
            int us = 0;
            switch (ts_type->unit()) {
                case arrow::TimeUnit::SECOND:
                    secs = val;
                    us = 0;
                    break;
                case arrow::TimeUnit::MILLI:
                    secs = val / 1000;
                    us = (val % 1000) * 1000;
                    break;
                case arrow::TimeUnit::MICRO:
                    secs = val / 1000000;
                    us = val % 1000000;
                    break;
                case arrow::TimeUnit::NANO:
                    secs = val / 1000000000;
                    us = (val % 1000000000) / 1000;
                    break;
            }
            return DateTimeNode::makeAbsolute(zone, secs, us);
        }

        case arrow::Type::TIME32: {
            auto time_array = std::static_pointer_cast<arrow::Time32Array>(array);
            auto time_type = std::static_pointer_cast<arrow::Time32Type>(array->type());
            int32_t val = time_array->Value(index);

            int64_t secs;
            int us = 0;
            if (time_type->unit() == arrow::TimeUnit::SECOND) {
                secs = val;
            } else {
                // MILLI
                secs = val / 1000;
                us = (val % 1000) * 1000;
            }
            // time-of-day as absolute date on epoch day
            return DateTimeNode::makeAbsolute(currentTZ(), secs, us);
        }

        case arrow::Type::TIME64: {
            auto time_array = std::static_pointer_cast<arrow::Time64Array>(array);
            auto time_type = std::static_pointer_cast<arrow::Time64Type>(array->type());
            int64_t val = time_array->Value(index);

            int64_t secs;
            int us;
            if (time_type->unit() == arrow::TimeUnit::MICRO) {
                secs = val / 1000000;
                us = val % 1000000;
            } else {
                // NANO
                secs = val / 1000000000;
                us = (val % 1000000000) / 1000;
            }
            return DateTimeNode::makeAbsolute(currentTZ(), secs, us);
        }

        case arrow::Type::DURATION: {
            auto dur_array = std::static_pointer_cast<arrow::DurationArray>(array);
            auto dur_type = std::static_pointer_cast<arrow::DurationType>(array->type());
            int64_t val = dur_array->Value(index);

            int64_t secs = 0;
            int us = 0;
            switch (dur_type->unit()) {
                case arrow::TimeUnit::SECOND:
                    secs = val;
                    us = 0;
                    break;
                case arrow::TimeUnit::MILLI:
                    secs = val / 1000;
                    us = (val % 1000) * 1000;
                    break;
                case arrow::TimeUnit::MICRO:
                    secs = val / 1000000;
                    us = val % 1000000;
                    break;
                case arrow::TimeUnit::NANO:
                    secs = val / 1000000000;
                    us = (val % 1000000000) / 1000;
                    break;
            }
            return DateTimeNode::makeRelative(0, 0, 0, 0, 0, secs, us);
        }

        case arrow::Type::DECIMAL128: {
            auto dec_array = std::static_pointer_cast<arrow::Decimal128Array>(array);
            auto dec_type = std::static_pointer_cast<arrow::Decimal128Type>(array->type());
            arrow::Decimal128 dec_val(dec_array->GetValue(index));
            std::string str = dec_val.ToString(dec_type->scale());
            return new QoreNumberNode(str.c_str());
        }
        case arrow::Type::DECIMAL256: {
            auto dec_array = std::static_pointer_cast<arrow::Decimal256Array>(array);
            auto dec_type = std::static_pointer_cast<arrow::Decimal256Type>(array->type());
            arrow::Decimal256 dec_val(dec_array->GetValue(index));
            std::string str = dec_val.ToString(dec_type->scale());
            return new QoreNumberNode(str.c_str());
        }

        case arrow::Type::NA:
            return QoreValue();

        case arrow::Type::STRUCT: {
            auto struct_array = std::static_pointer_cast<arrow::StructArray>(array);
            auto struct_type = struct_array->type();
            ReferenceHolder<QoreHashNode> hash(new QoreHashNode(autoTypeInfo), xsink);

            for (int i = 0; i < struct_type->num_fields(); ++i) {
                auto child = struct_array->field(i);
                QoreValue child_val = scalarToQore(child, index, xsink);
                if (*xsink) {
                    return QoreValue();
                }
                hash->setKeyValue(struct_type->field(i)->name(), child_val, xsink);
            }
            return hash.release();
        }

        case arrow::Type::LIST: {
            auto list_array = std::static_pointer_cast<arrow::ListArray>(array);
            auto values = list_array->values();
            int64_t start = list_array->value_offset(index);
            int64_t length = list_array->value_length(index);

            ReferenceHolder<QoreListNode> list(new QoreListNode(autoTypeInfo), xsink);
            for (int64_t i = 0; i < length; ++i) {
                QoreValue elem = scalarToQore(values, start + i, xsink);
                if (*xsink) {
                    return QoreValue();
                }
                list->push(elem, xsink);
            }
            return list.release();
        }
        case arrow::Type::LARGE_LIST: {
            auto list_array = std::static_pointer_cast<arrow::LargeListArray>(array);
            auto values = list_array->values();
            int64_t start = list_array->value_offset(index);
            int64_t length = list_array->value_length(index);

            ReferenceHolder<QoreListNode> list(new QoreListNode(autoTypeInfo), xsink);
            for (int64_t i = 0; i < length; ++i) {
                QoreValue elem = scalarToQore(values, start + i, xsink);
                if (*xsink) {
                    return QoreValue();
                }
                list->push(elem, xsink);
            }
            return list.release();
        }
        case arrow::Type::FIXED_SIZE_LIST: {
            auto list_array = std::static_pointer_cast<arrow::FixedSizeListArray>(array);
            auto values = list_array->values();
            int64_t start = list_array->value_offset(index);
            int64_t length = list_array->value_length(index);

            ReferenceHolder<QoreListNode> list(new QoreListNode(autoTypeInfo), xsink);
            for (int64_t i = 0; i < length; ++i) {
                QoreValue elem = scalarToQore(values, start + i, xsink);
                if (*xsink) {
                    return QoreValue();
                }
                list->push(elem, xsink);
            }
            return list.release();
        }

        case arrow::Type::MAP: {
            auto map_array = std::static_pointer_cast<arrow::MapArray>(array);
            auto keys = map_array->keys();
            auto items = map_array->items();
            int64_t start = map_array->value_offset(index);
            int64_t length = map_array->value_length(index);

            ReferenceHolder<QoreHashNode> hash(new QoreHashNode(autoTypeInfo), xsink);
            for (int64_t i = 0; i < length; ++i) {
                // keys must be strings for Qore hash conversion
                ValueHolder key_val(scalarToQore(keys, start + i, xsink), xsink);
                if (*xsink) {
                    return QoreValue();
                }
                QoreStringValueHelper key_str(*key_val);
                QoreValue item_val = scalarToQore(items, start + i, xsink);
                if (*xsink) {
                    return QoreValue();
                }
                hash->setKeyValue(key_str->c_str(), item_val, xsink);
            }
            return hash.release();
        }

        case arrow::Type::DICTIONARY: {
            auto dict_array = std::static_pointer_cast<arrow::DictionaryArray>(array);
            auto indices = dict_array->indices();
            auto dictionary = dict_array->dictionary();

            // Resolve the dictionary index to the actual value
            auto idx_val = scalarToQore(indices, index, xsink);
            if (*xsink || idx_val.isNothing()) {
                return QoreValue();
            }
            int64_t dict_index = idx_val.getAsBigInt();
            if (dict_index < 0 || dict_index >= dictionary->length()) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "dictionary index %lld out of range (0..%lld)",
                    (long long)dict_index, (long long)(dictionary->length() - 1));
                return QoreValue();
            }
            return scalarToQore(dictionary, dict_index, xsink);
        }

        case arrow::Type::DENSE_UNION: {
            auto union_array = std::static_pointer_cast<arrow::DenseUnionArray>(array);
            int child_id = union_array->child_id(index);
            auto child = union_array->field(child_id);
            int64_t offset = union_array->value_offset(index);
            return scalarToQore(child, offset, xsink);
        }
        case arrow::Type::SPARSE_UNION: {
            auto union_array = std::static_pointer_cast<arrow::SparseUnionArray>(array);
            int child_id = union_array->child_id(index);
            auto child = union_array->field(child_id);
            return scalarToQore(child, index, xsink);
        }

        default:
            xsink->raiseException("ARROW-TYPE-ERROR",
                "unsupported Arrow type: %s", array->type()->ToString().c_str());
            return QoreValue();
    }
}

QoreListNode* QoreArrowHelper::arrayToList(const std::shared_ptr<arrow::Array>& array,
        ExceptionSink* xsink) {
    ReferenceHolder<QoreListNode> list(new QoreListNode(autoTypeInfo), xsink);

    for (int64_t i = 0; i < array->length(); ++i) {
        if (!(i & 0xff) && i > 0 && qore_check_cancel(xsink)) {
            return nullptr;
        }
        QoreValue val = scalarToQore(array, i, xsink);
        if (*xsink) {
            return nullptr;
        }
        list->push(val, xsink);
    }

    return list.release();
}

bool QoreArrowHelper::appendToBuilder(arrow::ArrayBuilder* builder,
        const std::shared_ptr<arrow::DataType>& type, QoreValue val, ExceptionSink* xsink) {
    if (val.isNothing() || val.isNull()) {
        auto status = builder->AppendNull();
        if (!status.ok()) {
            xsink->raiseException("ARROW-BUILD-ERROR",
                "failed to append null: %s", status.ToString().c_str());
            return false;
        }
        return true;
    }

    arrow::Status status;

    switch (type->id()) {
        case arrow::Type::BOOL:
            status = static_cast<arrow::BooleanBuilder*>(builder)->Append(val.getAsBool());
            break;

        case arrow::Type::INT8:
            status = static_cast<arrow::Int8Builder*>(builder)->Append(
                (int8_t)val.getAsBigInt());
            break;
        case arrow::Type::INT16:
            status = static_cast<arrow::Int16Builder*>(builder)->Append(
                (int16_t)val.getAsBigInt());
            break;
        case arrow::Type::INT32:
            status = static_cast<arrow::Int32Builder*>(builder)->Append(
                (int32_t)val.getAsBigInt());
            break;
        case arrow::Type::INT64:
            status = static_cast<arrow::Int64Builder*>(builder)->Append(
                val.getAsBigInt());
            break;

        case arrow::Type::UINT8:
            status = static_cast<arrow::UInt8Builder*>(builder)->Append(
                (uint8_t)val.getAsBigInt());
            break;
        case arrow::Type::UINT16:
            status = static_cast<arrow::UInt16Builder*>(builder)->Append(
                (uint16_t)val.getAsBigInt());
            break;
        case arrow::Type::UINT32:
            status = static_cast<arrow::UInt32Builder*>(builder)->Append(
                (uint32_t)val.getAsBigInt());
            break;
        case arrow::Type::UINT64: {
            // Handle number type for values above INT64_MAX
            uint64_t uv;
            if (val.getType() == NT_NUMBER) {
                QoreStringValueHelper str(val);
                uv = strtoull(str->c_str(), nullptr, 10);
            } else {
                uv = (uint64_t)val.getAsBigInt();
            }
            status = static_cast<arrow::UInt64Builder*>(builder)->Append(uv);
            break;
        }

        case arrow::Type::HALF_FLOAT:
            status = static_cast<arrow::HalfFloatBuilder*>(builder)->Append(
                arrow::util::Float16::FromFloat((float)val.getAsFloat()).bits());
            break;
        case arrow::Type::FLOAT:
            status = static_cast<arrow::FloatBuilder*>(builder)->Append(
                (float)val.getAsFloat());
            break;
        case arrow::Type::DOUBLE:
            status = static_cast<arrow::DoubleBuilder*>(builder)->Append(
                val.getAsFloat());
            break;

        case arrow::Type::STRING: {
            QoreStringValueHelper str(val);
            status = static_cast<arrow::StringBuilder*>(builder)->Append(
                str->c_str(), str->size());
            break;
        }
        case arrow::Type::LARGE_STRING: {
            QoreStringValueHelper str(val);
            status = static_cast<arrow::LargeStringBuilder*>(builder)->Append(
                str->c_str(), str->size());
            break;
        }

        case arrow::Type::BINARY: {
            const BinaryNode* bin = val.get<BinaryNode>();
            if (bin) {
                status = static_cast<arrow::BinaryBuilder*>(builder)->Append(
                    static_cast<const uint8_t*>(bin->getPtr()), bin->size());
            } else {
                status = builder->AppendNull();
            }
            break;
        }
        case arrow::Type::LARGE_BINARY: {
            const BinaryNode* bin = val.get<BinaryNode>();
            if (bin) {
                status = static_cast<arrow::LargeBinaryBuilder*>(builder)->Append(
                    static_cast<const uint8_t*>(bin->getPtr()), bin->size());
            } else {
                status = builder->AppendNull();
            }
            break;
        }
        case arrow::Type::FIXED_SIZE_BINARY: {
            const BinaryNode* bin = val.get<BinaryNode>();
            if (bin) {
                auto fsb_type = std::static_pointer_cast<arrow::FixedSizeBinaryType>(type);
                if ((int)bin->size() != fsb_type->byte_width()) {
                    xsink->raiseException("ARROW-TYPE-ERROR",
                        "fixed_size_binary expects %d bytes, got %d",
                        fsb_type->byte_width(), (int)bin->size());
                    return false;
                }
                status = static_cast<arrow::FixedSizeBinaryBuilder*>(builder)->Append(
                    static_cast<const uint8_t*>(bin->getPtr()));
            } else {
                status = builder->AppendNull();
            }
            break;
        }

        case arrow::Type::DATE32: {
            const DateTimeNode* dt = val.get<DateTimeNode>();
            if (dt) {
                // Extract date components in the date's own timezone to avoid
                // timezone offset causing an off-by-one day error
                qore_tm info;
                dt->getInfo(info);
                struct tm tm_info = {};
                tm_info.tm_year = info.year - 1900;
                tm_info.tm_mon = info.month - 1;
                tm_info.tm_mday = info.day;
                time_t epoch = timegm(&tm_info);
                int32_t days = (int32_t)(epoch / 86400);
                status = static_cast<arrow::Date32Builder*>(builder)->Append(days);
            } else {
                status = builder->AppendNull();
            }
            break;
        }
        case arrow::Type::DATE64: {
            const DateTimeNode* dt = val.get<DateTimeNode>();
            if (dt) {
                // Extract date components in the date's own timezone
                qore_tm info;
                dt->getInfo(info);
                struct tm tm_info = {};
                tm_info.tm_year = info.year - 1900;
                tm_info.tm_mon = info.month - 1;
                tm_info.tm_mday = info.day;
                time_t epoch = timegm(&tm_info);
                int64_t ms = static_cast<int64_t>(epoch) * 1000;
                status = static_cast<arrow::Date64Builder*>(builder)->Append(ms);
            } else {
                status = builder->AppendNull();
            }
            break;
        }

        case arrow::Type::TIMESTAMP: {
            const DateTimeNode* dt = val.get<DateTimeNode>();
            if (dt) {
                auto ts_type = std::static_pointer_cast<arrow::TimestampType>(type);
                int64_t epoch = dt->getEpochSecondsUTC();
                int64_t us = dt->getMicrosecond();
                int64_t ts_val = 0;
                switch (ts_type->unit()) {
                    case arrow::TimeUnit::SECOND:
                        ts_val = epoch;
                        break;
                    case arrow::TimeUnit::MILLI:
                        ts_val = epoch * 1000 + us / 1000;
                        break;
                    case arrow::TimeUnit::MICRO:
                        ts_val = epoch * 1000000 + us;
                        break;
                    case arrow::TimeUnit::NANO:
                        ts_val = epoch * 1000000000 + us * 1000;
                        break;
                }
                status = static_cast<arrow::TimestampBuilder*>(builder)->Append(ts_val);
            } else {
                status = builder->AppendNull();
            }
            break;
        }

        case arrow::Type::TIME32: {
            const DateTimeNode* dt = val.get<DateTimeNode>();
            if (dt) {
                auto time_type = std::static_pointer_cast<arrow::Time32Type>(type);
                // extract time-of-day
                qore_tm info;
                dt->getInfo(info);
                int32_t secs_of_day = info.hour * 3600 + info.minute * 60 + info.second;
                int32_t tv;
                if (time_type->unit() == arrow::TimeUnit::SECOND) {
                    tv = secs_of_day;
                } else {
                    tv = secs_of_day * 1000 + info.us / 1000;
                }
                status = static_cast<arrow::Time32Builder*>(builder)->Append(tv);
            } else {
                status = builder->AppendNull();
            }
            break;
        }
        case arrow::Type::TIME64: {
            const DateTimeNode* dt = val.get<DateTimeNode>();
            if (dt) {
                auto time_type = std::static_pointer_cast<arrow::Time64Type>(type);
                qore_tm info;
                dt->getInfo(info);
                int64_t secs_of_day = info.hour * 3600 + info.minute * 60 + info.second;
                int64_t tv;
                if (time_type->unit() == arrow::TimeUnit::MICRO) {
                    tv = secs_of_day * 1000000 + info.us;
                } else {
                    tv = secs_of_day * 1000000000 + (int64_t)info.us * 1000;
                }
                status = static_cast<arrow::Time64Builder*>(builder)->Append(tv);
            } else {
                status = builder->AppendNull();
            }
            break;
        }

        case arrow::Type::DURATION: {
            const DateTimeNode* dt = val.get<DateTimeNode>();
            if (dt) {
                auto dur_type = std::static_pointer_cast<arrow::DurationType>(type);
                int64_t secs = dt->getRelativeSeconds();
                int64_t us = dt->getRelativeMicroseconds();
                int64_t dv = 0;
                switch (dur_type->unit()) {
                    case arrow::TimeUnit::SECOND:
                        dv = secs;
                        break;
                    case arrow::TimeUnit::MILLI:
                        dv = secs * 1000 + us / 1000;
                        break;
                    case arrow::TimeUnit::MICRO:
                        dv = secs * 1000000 + us;
                        break;
                    case arrow::TimeUnit::NANO:
                        dv = secs * 1000000000 + us * 1000;
                        break;
                }
                status = static_cast<arrow::DurationBuilder*>(builder)->Append(dv);
            } else {
                status = builder->AppendNull();
            }
            break;
        }

        case arrow::Type::DECIMAL128: {
            auto dec_type = std::static_pointer_cast<arrow::Decimal128Type>(type);
            QoreStringValueHelper str(val);
            arrow::Decimal128 dec_val;
            int32_t out_precision, out_scale;
            auto parse_status = arrow::Decimal128::FromString(
                std::string(str->c_str()), &dec_val, &out_precision, &out_scale);
            if (!parse_status.ok()) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "failed to parse decimal128 value '%s': %s",
                    str->c_str(), parse_status.ToString().c_str());
                return false;
            }
            // Rescale to target scale if needed
            if (out_scale != dec_type->scale()) {
                auto rescale_result = dec_val.Rescale(out_scale, dec_type->scale());
                if (!rescale_result.ok()) {
                    xsink->raiseException("ARROW-TYPE-ERROR",
                        "failed to rescale decimal128 value: %s",
                        rescale_result.status().ToString().c_str());
                    return false;
                }
                dec_val = std::move(rescale_result).ValueUnsafe();
            }
            status = static_cast<arrow::Decimal128Builder*>(builder)->Append(dec_val);
            break;
        }
        case arrow::Type::DECIMAL256: {
            auto dec_type = std::static_pointer_cast<arrow::Decimal256Type>(type);
            QoreStringValueHelper str(val);
            arrow::Decimal256 dec_val;
            int32_t out_precision, out_scale;
            auto parse_status = arrow::Decimal256::FromString(
                std::string(str->c_str()), &dec_val, &out_precision, &out_scale);
            if (!parse_status.ok()) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "failed to parse decimal256 value '%s': %s",
                    str->c_str(), parse_status.ToString().c_str());
                return false;
            }
            if (out_scale != dec_type->scale()) {
                auto rescale_result = dec_val.Rescale(out_scale, dec_type->scale());
                if (!rescale_result.ok()) {
                    xsink->raiseException("ARROW-TYPE-ERROR",
                        "failed to rescale decimal256 value: %s",
                        rescale_result.status().ToString().c_str());
                    return false;
                }
                dec_val = std::move(rescale_result).ValueUnsafe();
            }
            status = static_cast<arrow::Decimal256Builder*>(builder)->Append(dec_val);
            break;
        }

        case arrow::Type::NA:
            status = builder->AppendNull();
            break;

        case arrow::Type::STRUCT: {
            auto struct_builder = static_cast<arrow::StructBuilder*>(builder);
            auto struct_type = std::static_pointer_cast<arrow::StructType>(type);
            const QoreHashNode* hash = val.get<QoreHashNode>();
            if (!hash) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "expected hash for struct field, got %s", val.getFullTypeName());
                return false;
            }
            status = struct_builder->Append();
            if (!status.ok()) {
                xsink->raiseException("ARROW-BUILD-ERROR",
                    "failed to append struct: %s", status.ToString().c_str());
                return false;
            }
            for (int i = 0; i < struct_type->num_fields(); ++i) {
                auto child_field = struct_type->field(i);
                QoreValue child_val = hash->getKeyValue(child_field->name().c_str());
                if (!appendToBuilder(struct_builder->child_builder(i).get(),
                        child_field->type(), child_val, xsink)) {
                    return false;
                }
            }
            return true;
        }

        case arrow::Type::LIST: {
            auto list_builder = static_cast<arrow::ListBuilder*>(builder);
            auto list_type = std::static_pointer_cast<arrow::ListType>(type);
            const QoreListNode* qlist = val.get<QoreListNode>();
            if (!qlist) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "expected list for list field, got %s", val.getFullTypeName());
                return false;
            }
            status = list_builder->Append();
            if (!status.ok()) {
                xsink->raiseException("ARROW-BUILD-ERROR",
                    "failed to append list: %s", status.ToString().c_str());
                return false;
            }
            auto value_builder = list_builder->value_builder();
            for (size_t i = 0; i < qlist->size(); ++i) {
                if (!appendToBuilder(value_builder, list_type->value_type(),
                        qlist->retrieveEntry(i), xsink)) {
                    return false;
                }
            }
            return true;
        }

        case arrow::Type::LARGE_LIST: {
            auto list_builder = static_cast<arrow::LargeListBuilder*>(builder);
            auto list_type = std::static_pointer_cast<arrow::LargeListType>(type);
            const QoreListNode* qlist = val.get<QoreListNode>();
            if (!qlist) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "expected list for large_list field, got %s", val.getFullTypeName());
                return false;
            }
            status = list_builder->Append();
            if (!status.ok()) {
                xsink->raiseException("ARROW-BUILD-ERROR",
                    "failed to append large_list: %s", status.ToString().c_str());
                return false;
            }
            auto value_builder = list_builder->value_builder();
            for (size_t i = 0; i < qlist->size(); ++i) {
                if (!appendToBuilder(value_builder, list_type->value_type(),
                        qlist->retrieveEntry(i), xsink)) {
                    return false;
                }
            }
            return true;
        }

        case arrow::Type::MAP: {
            auto map_builder = static_cast<arrow::MapBuilder*>(builder);
            auto map_type = std::static_pointer_cast<arrow::MapType>(type);
            const QoreHashNode* hash = val.get<QoreHashNode>();
            if (!hash) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "expected hash for map field, got %s", val.getFullTypeName());
                return false;
            }
            status = map_builder->Append();
            if (!status.ok()) {
                xsink->raiseException("ARROW-BUILD-ERROR",
                    "failed to append map: %s", status.ToString().c_str());
                return false;
            }
            auto key_builder = map_builder->key_builder();
            auto item_builder = map_builder->item_builder();
            ConstHashIterator hi(hash);
            while (hi.next()) {
                // Map keys are always strings from Qore hash keys
                SimpleRefHolder<QoreStringNode> key_str(new QoreStringNode(hi.getKey()));
                QoreValue key_qv(*key_str);
                if (!appendToBuilder(key_builder, map_type->key_type(), key_qv, xsink)) {
                    return false;
                }
                if (!appendToBuilder(item_builder, map_type->item_type(), hi.get(), xsink)) {
                    return false;
                }
            }
            return true;
        }

        default:
            xsink->raiseException("ARROW-TYPE-ERROR",
                "unsupported Arrow type for building: %s", type->ToString().c_str());
            return false;
    }

    if (!status.ok()) {
        xsink->raiseException("ARROW-BUILD-ERROR",
            "failed to append value: %s", status.ToString().c_str());
        return false;
    }
    return true;
}

std::shared_ptr<arrow::Array> QoreArrowHelper::listToArray(
        const std::shared_ptr<arrow::DataType>& type,
        const QoreListNode* list, ExceptionSink* xsink) {
    auto result = arrow::MakeBuilder(type, arrow::default_memory_pool());
    if (!result.ok()) {
        xsink->raiseException("ARROW-BUILD-ERROR",
            "failed to create builder for type %s: %s",
            type->ToString().c_str(), result.status().ToString().c_str());
        return nullptr;
    }
    auto builder = std::move(result).ValueUnsafe();

    // Pre-allocate capacity to avoid repeated reallocations
    auto reserve_status = builder->Reserve(list->size());
    if (!reserve_status.ok()) {
        xsink->raiseException("ARROW-BUILD-ERROR",
            "failed to reserve capacity for %d elements: %s",
            (int)list->size(), reserve_status.ToString().c_str());
        return nullptr;
    }

    for (size_t i = 0; i < list->size(); ++i) {
        if (!(i & 0xff) && i > 0 && qore_check_cancel(xsink)) {
            return nullptr;
        }
        if (!appendToBuilder(builder.get(), type, list->retrieveEntry(i), xsink)) {
            return nullptr;
        }
    }

    auto finish_result = builder->Finish();
    if (!finish_result.ok()) {
        xsink->raiseException("ARROW-BUILD-ERROR",
            "failed to finish building array: %s", finish_result.status().ToString().c_str());
        return nullptr;
    }
    return std::move(finish_result).ValueUnsafe();
}

QoreHashNode* QoreArrowHelper::fieldToHash(const std::shared_ptr<arrow::Field>& field,
        ExceptionSink* xsink) {
    ReferenceHolder<QoreHashNode> hash(new QoreHashNode(autoTypeInfo), xsink);

    hash->setKeyValue("name", new QoreStringNode(field->name()), xsink);
    hash->setKeyValue("type", new QoreStringNode(typeName(field->type())), xsink);
    hash->setKeyValue("nullable", field->nullable(), xsink);

    // metadata
    if (field->metadata()) {
        hash->setKeyValue("metadata", metadataToHash(field->metadata(), xsink), xsink);
    }

    // children (for nested types)
    auto type = field->type();
    if (type->num_fields() > 0) {
        ReferenceHolder<QoreListNode> children(new QoreListNode(autoTypeInfo), xsink);
        for (int i = 0; i < type->num_fields(); ++i) {
            QoreHashNode* child_hash = fieldToHash(type->field(i), xsink);
            if (*xsink) {
                return nullptr;
            }
            children->push(child_hash, xsink);
        }
        hash->setKeyValue("children", children.release(), xsink);
    }

    return hash.release();
}

QoreHashNode* QoreArrowHelper::metadataToHash(
        const std::shared_ptr<const arrow::KeyValueMetadata>& metadata,
        ExceptionSink* xsink) {
    if (!metadata) {
        return nullptr;
    }

    ReferenceHolder<QoreHashNode> hash(new QoreHashNode(autoTypeInfo), xsink);
    for (int64_t i = 0; i < metadata->size(); ++i) {
        hash->setKeyValue(metadata->key(i), new QoreStringNode(metadata->value(i)), xsink);
    }
    return hash.release();
}

std::shared_ptr<arrow::KeyValueMetadata> QoreArrowHelper::hashToMetadata(
        const QoreHashNode* hash) {
    if (!hash) {
        return nullptr;
    }

    auto metadata = std::make_shared<arrow::KeyValueMetadata>();
    ConstHashIterator hi(hash);
    while (hi.next()) {
        QoreStringValueHelper str(hi.get());
        metadata->Append(hi.getKey(), std::string(str->c_str()));
    }
    return metadata;
}

QoreHashNode* QoreArrowHelper::schemaToHash(const std::shared_ptr<arrow::Schema>& schema,
        ExceptionSink* xsink) {
    ReferenceHolder<QoreHashNode> hash(new QoreHashNode(autoTypeInfo), xsink);

    // fields
    ReferenceHolder<QoreListNode> fields(new QoreListNode(autoTypeInfo), xsink);
    for (int i = 0; i < schema->num_fields(); ++i) {
        QoreHashNode* field_hash = fieldToHash(schema->field(i), xsink);
        if (*xsink) {
            return nullptr;
        }
        fields->push(field_hash, xsink);
    }
    hash->setKeyValue("fields", fields.release(), xsink);

    // metadata
    if (schema->metadata()) {
        hash->setKeyValue("metadata", metadataToHash(schema->metadata(), xsink), xsink);
    }

    return hash.release();
}

std::shared_ptr<arrow::Field> QoreArrowHelper::hashToField(
        const QoreHashNode* field_hash, ExceptionSink* xsink) {
    if (!field_hash) {
        xsink->raiseException("ARROW-SCHEMA-ERROR", "null field definition");
        return nullptr;
    }

    // name (required)
    QoreValue name_val = field_hash->getKeyValue("name");
    if (name_val.isNothing()) {
        xsink->raiseException("ARROW-SCHEMA-ERROR", "field definition missing 'name'");
        return nullptr;
    }
    QoreStringValueHelper name_str(name_val);

    // type (required)
    QoreValue type_val = field_hash->getKeyValue("type");
    if (type_val.isNothing()) {
        xsink->raiseException("ARROW-SCHEMA-ERROR", "field definition missing 'type'");
        return nullptr;
    }
    QoreStringValueHelper type_str(type_val);
    auto data_type = parseTypeName(type_str->c_str(), xsink);
    if (!data_type) {
        return nullptr;
    }

    // nullable (default true)
    bool nullable = true;
    QoreValue nullable_val = field_hash->getKeyValue("nullable");
    if (!nullable_val.isNothing()) {
        nullable = nullable_val.getAsBool();
    }

    // metadata (optional)
    std::shared_ptr<arrow::KeyValueMetadata> metadata;
    const QoreHashNode* meta_hash = field_hash->getKeyValue("metadata").get<QoreHashNode>();
    if (meta_hash) {
        metadata = hashToMetadata(meta_hash);
    }

    // children (for nested types that need them at construction time)
    QoreValue children_val = field_hash->getKeyValue("children");
    const QoreListNode* children = children_val.get<QoreListNode>();
    if (children && children->size() > 0) {
        // For struct, list, map types - we need to build child fields
        if (data_type->id() == arrow::Type::STRUCT) {
            arrow::FieldVector child_fields;
            for (size_t i = 0; i < children->size(); ++i) {
                const QoreHashNode* child_hash = children->retrieveEntry(i).get<QoreHashNode>();
                auto child_field = hashToField(child_hash, xsink);
                if (!child_field) {
                    return nullptr;
                }
                child_fields.push_back(child_field);
            }
            data_type = arrow::struct_(child_fields);
        } else if (data_type->id() == arrow::Type::LIST && children->size() >= 1) {
            const QoreHashNode* child_hash = children->retrieveEntry(0).get<QoreHashNode>();
            auto child_field = hashToField(child_hash, xsink);
            if (!child_field) {
                return nullptr;
            }
            data_type = arrow::list(child_field);
        } else if (data_type->id() == arrow::Type::LARGE_LIST && children->size() >= 1) {
            const QoreHashNode* child_hash = children->retrieveEntry(0).get<QoreHashNode>();
            auto child_field = hashToField(child_hash, xsink);
            if (!child_field) {
                return nullptr;
            }
            data_type = arrow::large_list(child_field);
        } else if (data_type->id() == arrow::Type::MAP && children->size() >= 2) {
            const QoreHashNode* key_hash = children->retrieveEntry(0).get<QoreHashNode>();
            auto key_field = hashToField(key_hash, xsink);
            if (!key_field) {
                return nullptr;
            }
            const QoreHashNode* val_hash = children->retrieveEntry(1).get<QoreHashNode>();
            auto val_field = hashToField(val_hash, xsink);
            if (!val_field) {
                return nullptr;
            }
            data_type = arrow::map(key_field->type(), val_field->type());
        }
    }

    return arrow::field(std::string(name_str->c_str()), data_type, nullable,
        metadata);
}

std::shared_ptr<arrow::Schema> QoreArrowHelper::hashToSchema(
        const QoreListNode* fields, const QoreHashNode* metadata, ExceptionSink* xsink) {
    arrow::FieldVector field_vec;

    for (size_t i = 0; i < fields->size(); ++i) {
        const QoreHashNode* field_hash = fields->retrieveEntry(i).get<QoreHashNode>();
        auto field = hashToField(field_hash, xsink);
        if (!field) {
            return nullptr;
        }
        field_vec.push_back(field);
    }

    auto arrow_metadata = hashToMetadata(metadata);
    return arrow::schema(field_vec, arrow_metadata);
}

std::shared_ptr<arrow::DataType> QoreArrowHelper::parseTypeName(const std::string& type_name,
        ExceptionSink* xsink) {
    // Basic types
    if (type_name == "bool") {
        return arrow::boolean();
    }
    if (type_name == "int8") {
        return arrow::int8();
    }
    if (type_name == "int16") {
        return arrow::int16();
    }
    if (type_name == "int32") {
        return arrow::int32();
    }
    if (type_name == "int64") {
        return arrow::int64();
    }
    if (type_name == "uint8") {
        return arrow::uint8();
    }
    if (type_name == "uint16") {
        return arrow::uint16();
    }
    if (type_name == "uint32") {
        return arrow::uint32();
    }
    if (type_name == "uint64") {
        return arrow::uint64();
    }
    if (type_name == "float16" || type_name == "halffloat" || type_name == "half_float") {
        return arrow::float16();
    }
    if (type_name == "float" || type_name == "float32") {
        return arrow::float32();
    }
    if (type_name == "double" || type_name == "float64") {
        return arrow::float64();
    }
    if (type_name == "string" || type_name == "utf8") {
        return arrow::utf8();
    }
    if (type_name == "large_string" || type_name == "large_utf8") {
        return arrow::large_utf8();
    }
    if (type_name == "binary") {
        return arrow::binary();
    }
    if (type_name == "large_binary") {
        return arrow::large_binary();
    }
    if (type_name == "date32" || type_name == "date32[day]") {
        return arrow::date32();
    }
    if (type_name == "date64" || type_name == "date64[ms]") {
        return arrow::date64();
    }
    if (type_name == "null") {
        return arrow::null();
    }

    // Timestamp types: timestamp[s], timestamp[ms], timestamp[us], timestamp[ns],
    // timestamp[us, tz=UTC], etc.
    if (type_name.substr(0, 9) == "timestamp") {
        auto bracket = type_name.find('[');
        if (bracket != std::string::npos) {
            auto end = type_name.find(']');
            if (end == std::string::npos) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "malformed timestamp type: %s", type_name.c_str());
                return nullptr;
            }
            std::string params = type_name.substr(bracket + 1, end - bracket - 1);
            arrow::TimeUnit::type unit = arrow::TimeUnit::MICRO;
            std::string tz;

            // Parse unit
            if (params.substr(0, 2) == "ns") {
                unit = arrow::TimeUnit::NANO;
            } else if (params.substr(0, 2) == "us") {
                unit = arrow::TimeUnit::MICRO;
            } else if (params.substr(0, 2) == "ms") {
                unit = arrow::TimeUnit::MILLI;
            } else if (params.substr(0, 1) == "s") {
                unit = arrow::TimeUnit::SECOND;
            }

            // Parse timezone
            auto tz_pos = params.find("tz=");
            if (tz_pos != std::string::npos) {
                tz = params.substr(tz_pos + 3);
            }

            return arrow::timestamp(unit, tz);
        }
        return arrow::timestamp(arrow::TimeUnit::MICRO);
    }

    // Time types: time32[s], time32[ms], time64[us], time64[ns]
    if (type_name.substr(0, 6) == "time32") {
        auto bracket = type_name.find('[');
        if (bracket != std::string::npos) {
            auto end = type_name.find(']');
            if (end == std::string::npos) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "malformed time32 type: %s", type_name.c_str());
                return nullptr;
            }
            std::string unit_str = type_name.substr(bracket + 1, end - bracket - 1);
            if (unit_str == "s") {
                return arrow::time32(arrow::TimeUnit::SECOND);
            }
            return arrow::time32(arrow::TimeUnit::MILLI);
        }
        return arrow::time32(arrow::TimeUnit::MILLI);
    }
    if (type_name.substr(0, 6) == "time64") {
        auto bracket = type_name.find('[');
        if (bracket != std::string::npos) {
            auto end = type_name.find(']');
            if (end == std::string::npos) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "malformed time64 type: %s", type_name.c_str());
                return nullptr;
            }
            std::string unit_str = type_name.substr(bracket + 1, end - bracket - 1);
            if (unit_str == "ns") {
                return arrow::time64(arrow::TimeUnit::NANO);
            }
            return arrow::time64(arrow::TimeUnit::MICRO);
        }
        return arrow::time64(arrow::TimeUnit::MICRO);
    }

    // Duration types: duration[s], duration[ms], duration[us], duration[ns]
    if (type_name.substr(0, 8) == "duration") {
        auto bracket = type_name.find('[');
        if (bracket != std::string::npos) {
            auto end = type_name.find(']');
            if (end == std::string::npos) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "malformed duration type: %s", type_name.c_str());
                return nullptr;
            }
            std::string unit_str = type_name.substr(bracket + 1, end - bracket - 1);
            if (unit_str == "s") {
                return arrow::duration(arrow::TimeUnit::SECOND);
            }
            if (unit_str == "ms") {
                return arrow::duration(arrow::TimeUnit::MILLI);
            }
            if (unit_str == "ns") {
                return arrow::duration(arrow::TimeUnit::NANO);
            }
            return arrow::duration(arrow::TimeUnit::MICRO);
        }
        return arrow::duration(arrow::TimeUnit::MICRO);
    }

    // Decimal types: decimal128(38, 10), decimal256(76, 20)
    if (type_name.substr(0, 10) == "decimal128") {
        auto paren = type_name.find('(');
        if (paren != std::string::npos) {
            try {
                auto end = type_name.find(')');
                std::string params = type_name.substr(paren + 1, end - paren - 1);
                auto comma = params.find(',');
                int precision = std::stoi(params.substr(0, comma));
                int scale = std::stoi(params.substr(comma + 1));
                return arrow::decimal128(precision, scale);
            } catch (const std::exception& e) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "invalid decimal128 type format '%s': %s", type_name.c_str(), e.what());
                return nullptr;
            }
        }
        return arrow::decimal128(38, 10);
    }
    if (type_name.substr(0, 10) == "decimal256") {
        auto paren = type_name.find('(');
        if (paren != std::string::npos) {
            try {
                auto end = type_name.find(')');
                std::string params = type_name.substr(paren + 1, end - paren - 1);
                auto comma = params.find(',');
                int precision = std::stoi(params.substr(0, comma));
                int scale = std::stoi(params.substr(comma + 1));
                return arrow::decimal256(precision, scale);
            } catch (const std::exception& e) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "invalid decimal256 type format '%s': %s", type_name.c_str(), e.what());
                return nullptr;
            }
        }
        return arrow::decimal256(76, 20);
    }

    // Fixed-size binary: fixed_size_binary[N]
    if (type_name.substr(0, 17) == "fixed_size_binary") {
        auto bracket = type_name.find('[');
        if (bracket != std::string::npos) {
            try {
                auto end = type_name.find(']');
                int size = std::stoi(type_name.substr(bracket + 1, end - bracket - 1));
                return arrow::fixed_size_binary(size);
            } catch (const std::exception& e) {
                xsink->raiseException("ARROW-TYPE-ERROR",
                    "invalid fixed_size_binary type format '%s': %s", type_name.c_str(), e.what());
                return nullptr;
            }
        }
        xsink->raiseException("ARROW-TYPE-ERROR",
            "fixed_size_binary requires a size: fixed_size_binary[N]");
        return nullptr;
    }

    // Struct type (without children -- children are added later from the children field)
    if (type_name == "struct") {
        return arrow::struct_({});
    }

    // List types
    if (type_name == "list") {
        return arrow::list(arrow::utf8());  // default element type; overridden by children
    }
    if (type_name == "large_list") {
        return arrow::large_list(arrow::utf8());
    }

    // Map type
    if (type_name == "map") {
        return arrow::map(arrow::utf8(), arrow::utf8());  // default; overridden by children
    }

    xsink->raiseException("ARROW-TYPE-ERROR",
        "unknown Arrow type name: '%s'", type_name.c_str());
    return nullptr;
}

std::string QoreArrowHelper::typeName(const std::shared_ptr<arrow::DataType>& type) {
    switch (type->id()) {
        case arrow::Type::BOOL:
            return "bool";
        case arrow::Type::INT8:
            return "int8";
        case arrow::Type::INT16:
            return "int16";
        case arrow::Type::INT32:
            return "int32";
        case arrow::Type::INT64:
            return "int64";
        case arrow::Type::UINT8:
            return "uint8";
        case arrow::Type::UINT16:
            return "uint16";
        case arrow::Type::UINT32:
            return "uint32";
        case arrow::Type::UINT64:
            return "uint64";
        case arrow::Type::HALF_FLOAT:
            return "float16";
        case arrow::Type::FLOAT:
            return "float32";
        case arrow::Type::DOUBLE:
            return "float64";
        case arrow::Type::STRING:
            return "utf8";
        case arrow::Type::LARGE_STRING:
            return "large_utf8";
        case arrow::Type::BINARY:
            return "binary";
        case arrow::Type::LARGE_BINARY:
            return "large_binary";
        case arrow::Type::DATE32:
            return "date32";
        case arrow::Type::DATE64:
            return "date64";
        case arrow::Type::NA:
            return "null";
        case arrow::Type::TIMESTAMP: {
            auto ts_type = std::static_pointer_cast<arrow::TimestampType>(type);
            std::string unit;
            switch (ts_type->unit()) {
                case arrow::TimeUnit::SECOND:
                    unit = "s";
                    break;
                case arrow::TimeUnit::MILLI:
                    unit = "ms";
                    break;
                case arrow::TimeUnit::MICRO:
                    unit = "us";
                    break;
                case arrow::TimeUnit::NANO:
                    unit = "ns";
                    break;
            }
            if (ts_type->timezone().empty()) {
                return "timestamp[" + unit + "]";
            }
            return "timestamp[" + unit + ", tz=" + ts_type->timezone() + "]";
        }
        case arrow::Type::DECIMAL128: {
            auto dec_type = std::static_pointer_cast<arrow::Decimal128Type>(type);
            return "decimal128(" + std::to_string(dec_type->precision()) + ", "
                + std::to_string(dec_type->scale()) + ")";
        }
        case arrow::Type::DECIMAL256: {
            auto dec_type = std::static_pointer_cast<arrow::Decimal256Type>(type);
            return "decimal256(" + std::to_string(dec_type->precision()) + ", "
                + std::to_string(dec_type->scale()) + ")";
        }
        case arrow::Type::TIME32: {
            auto time_type = std::static_pointer_cast<arrow::Time32Type>(type);
            return time_type->unit() == arrow::TimeUnit::SECOND
                ? "time32[s]" : "time32[ms]";
        }
        case arrow::Type::TIME64: {
            auto time_type = std::static_pointer_cast<arrow::Time64Type>(type);
            return time_type->unit() == arrow::TimeUnit::NANO
                ? "time64[ns]" : "time64[us]";
        }
        case arrow::Type::DURATION: {
            auto dur_type = std::static_pointer_cast<arrow::DurationType>(type);
            std::string unit;
            switch (dur_type->unit()) {
                case arrow::TimeUnit::SECOND: unit = "s"; break;
                case arrow::TimeUnit::MILLI: unit = "ms"; break;
                case arrow::TimeUnit::MICRO: unit = "us"; break;
                case arrow::TimeUnit::NANO: unit = "ns"; break;
            }
            return "duration[" + unit + "]";
        }
        case arrow::Type::FIXED_SIZE_BINARY: {
            auto fsb_type = std::static_pointer_cast<arrow::FixedSizeBinaryType>(type);
            return "fixed_size_binary[" + std::to_string(fsb_type->byte_width()) + "]";
        }
        case arrow::Type::STRUCT:
            return "struct";
        case arrow::Type::LIST:
            return "list";
        case arrow::Type::LARGE_LIST:
            return "large_list";
        case arrow::Type::MAP:
            return "map";
        default:
            return type->ToString();
    }
}

QoreHashNode* QoreArrowHelper::recordBatchToIpc(
        const std::shared_ptr<arrow::RecordBatch>& batch, ExceptionSink* xsink) {
    // Get the IPC payload
    arrow::ipc::IpcPayload payload;
    auto status = arrow::ipc::GetRecordBatchPayload(
        *batch, arrow::ipc::IpcWriteOptions::Defaults(), &payload);
    if (!status.ok()) {
        xsink->raiseException("ARROW-IPC-ERROR",
            "failed to get record batch payload: %s", status.ToString().c_str());
        return nullptr;
    }

    // data_header = payload.metadata
    SimpleRefHolder<BinaryNode> header_bin(new BinaryNode);
    header_bin->append(payload.metadata->data(), payload.metadata->size());

    // data_body = concatenated body buffers
    // Calculate total body size
    int64_t body_size = 0;
    for (const auto& buf : payload.body_buffers) {
        if (buf) {
            // Pad each buffer to 8-byte alignment
            int64_t padded = (buf->size() + 7) & ~7;
            body_size += padded;
        } else {
            // null buffer still occupies padded space (0 bytes)
        }
    }

    SimpleRefHolder<BinaryNode> body_bin(new BinaryNode);
    if (body_size > 0) {
        // Allocate capacity but reset logical size to 0 so append() works correctly
        body_bin->preallocate(body_size);
        body_bin->setSize(0);
        for (const auto& buf : payload.body_buffers) {
            if (buf && buf->size() > 0) {
                body_bin->append(buf->data(), buf->size());
                // Pad to 8-byte alignment
                int64_t pad = ((buf->size() + 7) & ~7) - buf->size();
                if (pad > 0) {
                    static const char zeros[8] = {0};
                    body_bin->append(zeros, pad);
                }
            }
        }
    }

    ReferenceHolder<QoreHashNode> result(new QoreHashNode(autoTypeInfo), xsink);
    result->setKeyValue("data_header", header_bin.release(), xsink);
    result->setKeyValue("data_body", body_bin.release(), xsink);

    return result.release();
}

std::shared_ptr<arrow::RecordBatch> QoreArrowHelper::ipcToRecordBatch(
        const std::shared_ptr<arrow::Schema>& schema,
        const BinaryNode* data_header, const BinaryNode* data_body,
        ExceptionSink* xsink) {
    if (!data_header || data_header->size() == 0) {
        xsink->raiseException("ARROW-IPC-ERROR", "empty or missing data_header");
        return nullptr;
    }

    // Copy data_header into an Arrow-owned mutable buffer (BinaryNode may be freed
    // after the constructor returns, but the RecordBatch retains references)
    auto header_alloc = arrow::AllocateResizableBuffer(data_header->size());
    if (!header_alloc.ok()) {
        xsink->raiseException("ARROW-IPC-ERROR",
            "failed to allocate header buffer: %s", header_alloc.status().ToString().c_str());
        return nullptr;
    }
    std::shared_ptr<arrow::ResizableBuffer> header_buf = std::move(header_alloc).ValueUnsafe();
    memcpy(header_buf->mutable_data(), data_header->getPtr(), data_header->size());

    // Copy data_body into an Arrow-owned mutable buffer
    std::shared_ptr<arrow::Buffer> body_buf;
    if (data_body && data_body->size() > 0) {
        auto body_alloc = arrow::AllocateResizableBuffer(data_body->size());
        if (!body_alloc.ok()) {
            xsink->raiseException("ARROW-IPC-ERROR",
                "failed to allocate body buffer: %s", body_alloc.status().ToString().c_str());
            return nullptr;
        }
        std::shared_ptr<arrow::ResizableBuffer> body_owned = std::move(body_alloc).ValueUnsafe();
        memcpy(body_owned->mutable_data(), data_body->getPtr(), data_body->size());
        body_buf = body_owned;
    } else {
        body_buf = std::make_shared<arrow::Buffer>(nullptr, 0);
    }

    // Create a Message from the header + body
    auto msg_result = arrow::ipc::Message::Open(header_buf, body_buf);
    if (!msg_result.ok()) {
        xsink->raiseException("ARROW-IPC-ERROR",
            "failed to open IPC message: %s", msg_result.status().ToString().c_str());
        return nullptr;
    }
    auto message = std::move(msg_result).ValueUnsafe();

    // Read the RecordBatch from the message
    arrow::ipc::DictionaryMemo dict_memo;
    auto batch_result = arrow::ipc::ReadRecordBatch(
        *message, schema, &dict_memo, arrow::ipc::IpcReadOptions::Defaults());
    if (!batch_result.ok()) {
        xsink->raiseException("ARROW-IPC-ERROR",
            "failed to read record batch from IPC: %s", batch_result.status().ToString().c_str());
        return nullptr;
    }

    return std::move(batch_result).ValueUnsafe();
}

BinaryNode* QoreArrowHelper::serializeSchema(
        const std::shared_ptr<arrow::Schema>& schema, ExceptionSink* xsink) {
    auto result = arrow::ipc::SerializeSchema(*schema, arrow::default_memory_pool());
    if (!result.ok()) {
        xsink->raiseException("ARROW-IPC-ERROR",
            "failed to serialize schema: %s", result.status().ToString().c_str());
        return nullptr;
    }

    auto buf = std::move(result).ValueUnsafe();
    SimpleRefHolder<BinaryNode> bin(new BinaryNode);
    bin->append(buf->data(), buf->size());
    return bin.release();
}

std::shared_ptr<arrow::Schema> QoreArrowHelper::deserializeSchema(
        const BinaryNode* data, ExceptionSink* xsink) {
    if (!data || data->size() == 0) {
        xsink->raiseException("ARROW-IPC-ERROR", "empty or missing schema data");
        return nullptr;
    }
    auto buf = arrow::Buffer::Wrap(
        static_cast<const uint8_t*>(data->getPtr()), data->size());

    arrow::io::BufferReader reader(buf);
    arrow::ipc::DictionaryMemo dict_memo;
    auto result = arrow::ipc::ReadSchema(&reader, &dict_memo);
    if (!result.ok()) {
        xsink->raiseException("ARROW-IPC-ERROR",
            "failed to deserialize schema: %s", result.status().ToString().c_str());
        return nullptr;
    }

    return std::move(result).ValueUnsafe();
}

BinaryNode* QoreArrowHelper::serializeSchemaPayload(
        const std::shared_ptr<arrow::Schema>& schema, ExceptionSink* xsink) {
    arrow::ipc::IpcPayload payload;
    arrow::ipc::DictionaryFieldMapper mapper(*schema);
    auto status = arrow::ipc::GetSchemaPayload(
        *schema, arrow::ipc::IpcWriteOptions::Defaults(), mapper, &payload);
    if (!status.ok()) {
        xsink->raiseException("ARROW-IPC-ERROR",
            "failed to get schema payload: %s", status.ToString().c_str());
        return nullptr;
    }

    SimpleRefHolder<BinaryNode> bin(new BinaryNode);
    bin->append(payload.metadata->data(), payload.metadata->size());
    return bin.release();
}

std::shared_ptr<arrow::Schema> QoreArrowHelper::deserializeSchemaPayload(
        const BinaryNode* data, ExceptionSink* xsink) {
    if (!data || data->size() == 0) {
        xsink->raiseException("ARROW-IPC-ERROR", "empty or missing schema payload data");
        return nullptr;
    }

    auto buf = arrow::Buffer::Wrap(
        static_cast<const uint8_t*>(data->getPtr()), data->size());

    // Open the raw flatbuffers Message (same format as record batch metadata)
    auto msg_result = arrow::ipc::Message::Open(buf, nullptr);
    if (!msg_result.ok()) {
        xsink->raiseException("ARROW-IPC-ERROR",
            "failed to open IPC message for schema: %s",
            msg_result.status().ToString().c_str());
        return nullptr;
    }
    auto message = std::move(msg_result).ValueUnsafe();

    arrow::ipc::DictionaryMemo dict_memo;
    auto result = arrow::ipc::ReadSchema(*message, &dict_memo);
    if (!result.ok()) {
        xsink->raiseException("ARROW-IPC-ERROR",
            "failed to read schema from IPC message: %s",
            result.status().ToString().c_str());
        return nullptr;
    }

    return std::move(result).ValueUnsafe();
}
