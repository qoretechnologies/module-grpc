Subscription credit and RPM layout audit
========================================

Copyright 2026 Qore Technologies, s.r.o.

Scope: subscription credit publication and serialized writes, deterministic protocol/concurrent regression, release notes, RPM layout/metadata and three staged artifact tests. All62 checks: 19 Pass, 43 N/A, 0 Fail. Existing Fedora/AlmaLinux grpc_tools deprecation is already approved; other functional/build/lint diagnostics are clean. No C++ implementation changes; Valgrind is not required. Source URL metadata was verified separately with all three parsers/SRPM builds; final native OBS and public-download checks remain delivery gates.

.. list-table:: Complete audit-changes checklist
   :header-rows: 1

   * - Check
     - Status
     - Evidence

   * - 1. Entry exists in doxygen/lang/120_modules.dox.tmpl (for modules in the Qore repo; N/A for external module repos)
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 2. Entry exists in doxygen/lang/900_release_notes.dox.tmpl (for modules in the Qore repo; external modules have release notes in their .qm)
     - Pass
     - External module release notes explain credit accounting during callback delivery and concurrent replenishment.

   * - 3. qore_user_module() or qore_external_user_module() call in CMakeLists.txt
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 4. Module added to QMOD list in CMakeLists.txt
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 5. .qm file has @section <lowercasemodname>intro as first doc section — must be all lowercase (e.g., avrodataproviderintro, not AvroDataProviderintro)
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 6. %modern in .qm file — no redundant %new-style, %require-types, %strict-args, %enable-all-warnings
     - Pass
     - The changed existing module and Qore regression use %modern.

   * - 7. No parse directives (%requires, %modern, %new-style) in separated .qc files (check OUTSIDE of @code blocks only)
     - Pass
     - No directives introduced in the separated subscription .qc.

   * - 8. No %include usage (deprecated for modules)
     - Pass
     - No %include directives added.

   * - 9. Copyright 2026 on all new files
     - Pass
     - New staged-layout regression and report carry Copyright 2026; changed module and Qore test already do.

   * - 10. Directory layout: .qm inside qlib/<ModuleName>/ directory (not at qlib/<ModuleName>.qm for multi-file modules)
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 11. No second .qm for the same module at qlib/<ModuleName>.qm
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 12. ns=Qore::XX matches the QoreNamespace constructor path
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 13. %modern directive present
     - Pass
     - salesforce-pubsub.qtest uses %modern.

   * - 14. Executable permission set (chmod +x)
     - Pass
     - Both Python staged-layout and Qore protocol regressions are executable.

   * - 15. Uses %prepend-module-path  before %requires for in-repo modules (Qore and Qore modules only; not Qorus)
     - Pass
     - The Qore test prepends its local qlib directory; qualification explicitly selects this source or its built AOT modules.

   * - 16. External module dependencies use %try-module — except modules delivered with the project itself (Qore ex: DataProvider, ConnectionProvider, QUnit, etc.) which use hard %requires
     - Pass
     - No new imports; existing core and in-repository modules retain hard requirements.

   * - 17. No filesystem operations (fopen, open, creat, unlink, remove, rename, mkdir, rmdir, stat, chmod) without sandbox checks
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 18. No network operations (connect, bind, socket, getaddrinfo, gethostbyname) without sandbox checks
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 19. If filesystem/network ops exist, verify QoreSandboxManagerHelper usage
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 20. No File::, Dir::, Socket::, HTTPClient:: usage without justification
     - Pass
     - The new test uses the existing loopback-only gRPC server; no new raw filesystem or network API in the runtime change.

   * - 21. All for/while loops that could iterate >100 times have qore_check_cancel() checks
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 22. Uses qore_check_cancel() (NOT deprecated qore_check_io_interrupt())
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 23. Check frequency: every 100 iterations for tight loops, every 10 for expensive iterations
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 24. No blocking operations without cancellation support
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 25. Every action has display_name, short_desc (plain text, <80 chars), desc (markdown)
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 26. Every action has options populated via getActionOptionFromFields() — without this, the action shows an empty, unusable form
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 27. Every action has output_type set to a typed data type constant (e.g., MyResponseDataType) — not omitted
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 28. DPAT_API actions: provider has "supports_request": True and implements doRequestImpl()
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 29. DPAT_FIND actions: every option exists in SearchOptions, getRecordTypeImpl() returns *hash<string, AbstractDataField>
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 30. Scheme-based apps (with "scheme" in registerApp): actions use "path" and do NOT use "cls" — having both scheme and cls causes a runtime error
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 31. Single-key hash slices use trailing comma: Fields{"key",} (without trailing comma, Fields{"key"} returns the value, not a hash)
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 32. Typed data type classes exist for request and response types — inherit HashDataType, have const Fields hash, call addQoreFields(Fields) in constructor, export public constant at bottom (e.g., public const MyDataType = new MyDataType();)
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 33. Request/input types use public Fields (enables ClassName::Fields in action registration)
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 34. Response/output types use private Fields
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 35. Each field in data types has display_name, type, and desc (markdown-formatted)
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 36. Input fields have example_value where useful (string fields, endpoint URIs, SQL queries, etc.)
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 37. Fields with finite allowed values use allowed_values with AllowedValueInfo containing both value and display_name (Title Case, human-readable) — never bare values, never described only in text
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 38. Password/secret fields have "sensitive": True
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 39. groups uses AppGroup enum values from qlib/DataProvider/AppGroup.qc
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 40. App logo stored as separate file, loaded at module level in Priv namespace
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 41. App desc uses markdown: bullet list of capabilities, links to project website, business-language explanation of value
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 42. display_name is user-friendly ("Apache Avro" not "avro")
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 43. short_desc is plain text, under 80 chars, single sentence — no markdown
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 44. desc uses markdown: backticks for code/field refs ( field_name ,  True ,  pdf ), \n\n for paragraphs, -  bullet lists for enumerations, bold for caveats
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 45. Descriptions use plain business language relating to common challenges — not just technical "what" but "why" and "when to use"
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 46. No bare True/False/NOTHING — must be backtick-wrapped in desc
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 47. No bare field/option names in prose — must use backticks
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 48. Long descriptions (>500 chars) use bold section headers and bullet lists
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 49. Factory registration in Qore repo: every factory name registered in qlib/DataProvider/DataProvider.qc → FactoryMap (without this, module loads but doesn't appear in Qorus apps)
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 50. getRecordTypeImpl() signature: must be private *hash<string, AbstractDataField> getRecordTypeImpl(*hash<auto> search_options) — NOT returning *AbstractDataProviderType
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 51. Dependency JARs committed (for JNI modules): JAR files in qlib/*/jar/ may be gitignored — use git add -f to ensure they're tracked, otherwise CI compilation fails
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 52. JAR install rules in CMakeLists.txt for all dependency JARs
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 53. No workarounds: No TODOs, FIXMEs, stubs, or partially-implemented features
     - Pass
     - Fix credit publication/order and atomic default grants; package the intended payload with exact interpreters and shared storage. No filtering, timeout increases or checks disabled.

   * - 54. Exception safety: C++ uses ReferenceHolder for Qore allocations, std::unique_ptr for C++ allocations, *xsink checked after every fallible operation
     - Pass
     - Write failures precede credit mutation; AutoLock releases on exceptions. Callback and worker gates are released on exit, and every worker decrements its completion counter.

   * - 55. Thread safety: All mutable shared state protected by std::lock_guard<std::mutex> or documented as immutable-after-construction
     - Pass
     - The subscription mutex covers default-deficit calculation, transport enqueue and accounting. gRPC callbacks execute outside the stream mutex; sendData queues without waiting for callback delivery. Eight synchronized callers grant exactly once.

   * - 56. Type safety: Strongly-typed code<return(args)> instead of untyped code; static_cast instead of C casts; typed hashdecls for results; enums where appropriate
     - Pass
     - Typed optional count, boolean return, hash arguments and Queue<hash<auto>>. Structured Python Path and subprocess operations.

   * - 57. Performance: No O(n²) where O(n) is possible; no unnecessary copies; coordinate descent uses incremental residuals not full matrix multiply
     - Pass
     - Constant-time credit update; no extra threads or polling in production. Fixture concurrency is bounded to eight workers.

   * - 58. Error handling: All inputs validated (dimensions, empty data, unfitted models); C++ I/O handles EAGAIN/EINTR if applicable
     - Pass
     - Existing invalid credit boundaries and stopped/reconnect paths remain covered. Added full-window and stopped-grant rejection; layout controls reject six actual broken payloads.

   * - 59. Documentation: Doxygen @param, @return, @throw on all public methods; @par Example with realistic business scenarios; @note for important caveats
     - Pass
     - Public replenish documentation and module release notes describe callback/concurrent guarantees. RPM guide documents exact examples, licensing, metadata and checksummed OBS source retrieval.

   * - 60. QPP flags: [flags=CONSTANT] on methods that never throw; [flags=RET_VALUE_ONLY] on methods that throw but have no side effects
     - N/A
     - No new module, QPP/C++ implementation, DataProvider registration/type/action, JNI dependency, sandbox/cancellation implementation or associated public API change in this scope. Existing provider registrations are untouched; the .qm change only adds release notes.

   * - 61. Security: No user-controlled format strings; no buffer overflows; bounds checking on array indices; no credentials in code
     - Pass
     - Only loopback synthetic protocol tests and public TLS identities; no credentials, warning filters or disabled functionality. Package paths and bytes checked against sources.

   * - 62. Correctness: Algorithms verified against reference implementations; edge cases tested (empty data, single sample, all-zero features)
     - Pass
     - All three full RPM builds:13 suites/379 cases/1790 assertions,4 dependency methods,3 layout methods,6 uninstall methods. Old runtime deterministically fails at credit2 versus10; final control passes20 runs/440 assertions. Complete target lint:zero errors/zero warnings, plus allthree final Source0 parser/SRPM checks.
