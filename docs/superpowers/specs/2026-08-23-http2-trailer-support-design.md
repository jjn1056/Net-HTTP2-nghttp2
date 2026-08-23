# HTTP/2 Trailer Support for Net::HTTP2::nghttp2 0.009

**Status:** Approved in design review on 2026-08-23<br>
**Implementation repository:** `Net-HTTP2-nghttp2` only<br>
**Target release:** 0.009

## 1. Summary

Net::HTTP2::nghttp2 0.008 can receive HTTP/2 trailers, but it cannot send
them through nghttp2's native trailer API. Its data-provider callback also
equates end-of-input with END_STREAM, so a caller cannot finish DATA while
leaving the stream open for trailing HEADERS.

Version 0.009 will add a thin `nghttp2_submit_trailer()` binding, extend the
streaming callback and `submit_data` contracts with an optional
`NO_END_STREAM` signal, expose native receive-side header categories, and
export the HTTP/2 wire error codes needed by consumers. Existing two-value
callbacks remain unchanged.

The binding will not add a second stream state machine around nghttp2.
`submit_trailer` will report errors returned immediately by nghttp2, while a
successful return means that the frame was queued rather than written to the
peer.

## 2. Goals

- Send response or request trailers as a trailing HEADERS frame with
  END_STREAM.
- Allow a data provider to return EOF without putting END_STREAM on DATA.
- Preserve all existing callback forms and `submit_data` calls.
- Let receivers distinguish native HEADERS categories without changing
  positional callback signatures.
- Export HTTP/2 wire error codes and header-category constants.
- Prove the feature with an in-memory client/server round trip.
- Publish the completed work as Net::HTTP2::nghttp2 0.009.
- Record, but do not implement, follow-up work for PAGI and PAGI::Server.

## 3. Non-goals

- No changes to the PAGI or PAGI::Server repositories.
- No automatic trailer queue or managed response lifecycle in this binding.
- No wrapper-side preflight for closed, unknown, or duplicate streams.
- No `on_frame_not_send` callback binding in 0.009.
- No synthetic `is_trailer` boolean.
- No registry of which HTTP field definitions permit use in trailers.
- No change to the meaning of static `body => $string` responses, which end
  their stream normally and therefore cannot be followed by trailers.

## 4. Repository ownership map

This map records the repositories considered during design. It must be
reconfirmed before implementation and again before any push.

| Repository | Path and reviewed revision | Ticket and branch | Owned work | Deployment and push boundary |
|---|---|---|---|---|
| Net::HTTP2::nghttp2 | `/Users/jnapiorkowski/Desktop/PAGI-Project/Net-HTTP2-nghttp2` at code revision `aa77d621e8dd3ffdb47eed2bbaf2600b0491928f`; `origin/main` at `818b57d438e31327a7355a5d136de65f95b5525e` | HTTP/2 trailers / 0.009; create `feat/http2-trailers-0.009` from the approved implementation-plan commit descended from `aa77d62` | XS, Perl API, tests, docs, version, distribution metadata | CPAN 0.009; feature branch and eventual main/tag push to `origin` after review |
| PAGI | `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` reviewed at `f04c0294f7480a8081ae80d1e2ac0f9ebaef2844` on `main` | Report-only next steps | None | No deployment or push |
| PAGI::Server | `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Server/.worktrees/pagi-0.4-alignment` reviewed at `c862a9112f4411091c09d74befe6ef31a402d412` on `fix/pagi-0.4-alignment` | Report-only Phase 2b integration | None | No deployment or push |

The Net::HTTP2::nghttp2 checkout already contains the untracked
`Net-HTTP2-nghttp2-0.008.tar.gz`. It is user-owned and must remain untouched.
The 0.008 source commit is also ahead of `origin/main`, so release work must
reconcile the remote and CPAN state before publishing 0.009.

The reviewed PAGI::Server alignment worktree also contains unrelated user
changes. It remains read-only for this project; neither planning nor
implementation may clean, switch, stage, or modify it.

## 5. Standards and native API constraints

RFC 9113 represents trailers as a final HEADERS block after all DATA. The
HEADERS frame starting that block carries END_STREAM, and pseudo-header fields
must not appear in a trailer section:

- <https://www.rfc-editor.org/rfc/rfc9113.html#section-8.8>
- <https://www.rfc-editor.org/rfc/rfc9113.html#section-8.3>

RFC 9110 treats trailers as a separate field section. A sender must know that
each field definition permits trailer use, and important metadata should not
depend solely on trailers because intermediaries might discard them:

- <https://www.rfc-editor.org/rfc/rfc9110.html#section-6.5>

The nghttp2 API requires the data callback to set
`NGHTTP2_DATA_FLAG_EOF | NGHTTP2_DATA_FLAG_NO_END_STREAM`, followed by
`nghttp2_submit_trailer()`. The native function may be called inside the data
read callback. It copies the submitted name/value pairs before returning:

- <https://nghttp2.org/documentation/nghttp2_submit_trailer.html>

For a server, the application is responsible for submitting trailers only
after response HEADERS and optional DATA without END_STREAM. nghttp2 does not
enforce the full ordering rule itself.

## 6. Public Perl API

### 6.1 `submit_trailer`

`Net::HTTP2::nghttp2::Session` will expose:

```perl
$session->submit_trailer(
    $stream_id,
    headers => [
        ['x-checksum', 'abc'],
        ['x-signature', 'xyz'],
    ],
);
```

`headers` defaults to `[]`. An empty list is meaningful: it submits an empty
trailer block whose HEADERS frame still carries END_STREAM and terminates the
stream.

The Perl wrapper validates that:

- `headers` is an array reference;
- every entry is a two-element array reference;
- both values are defined non-reference scalars; and
- no field name begins with `:`.

Validation failures croak with a message identifying `submit_trailer` and the
invalid input. Duplicate field names and input order are preserved. nghttp2
lowercases ordinary names as part of submission, matching its documented
behavior.

The wrapper calls a private `_submit_trailer_xs($stream_id, $headers)` method.
The XS method calls `nghttp2_submit_trailer`, croaks on an immediate negative
return using `nghttp2_strerror`, and otherwise returns `0`.

The binding does not attempt to decide whether an ordinary field is
semantically allowed in trailers. That remains the caller's responsibility
under RFC 9110.

### 6.2 Streaming callback contract

Streaming request and response callbacks will accept an optional third return
value:

```perl
return ($data, $eof, $no_end_stream);
```

The complete contract is:

| Return | Meaning |
|---|---|
| `undef` or an empty list | Defer; resume later with `resume_stream` |
| `$data` | Send data and keep the provider active |
| `($data, $eof)` | Existing behavior; true EOF ends the stream normally |
| `($data, $eof, $no_end_stream)` | When both flags are true, finish DATA without END_STREAM so trailers can follow |

The third value has no effect when EOF is false. This is documented rather
than treated as a callback failure. A defined empty string with EOF remains a
valid way to finish an empty data source. A defined empty string without EOF
continues to defer, preserving current behavior.

The XS callback must read the first three Perl return values correctly without
confusing stack order, and it must discard any surplus return values safely.
Existing one- and two-value returns must remain byte-for-byte compatible.

When EOF and `no_end_stream` are both true, XS sets:

```text
NGHTTP2_DATA_FLAG_EOF
NGHTTP2_DATA_FLAG_NO_END_STREAM
```

The caller may invoke `submit_trailer` either inside that callback invocation
or after the callback has returned and the provider has reached EOF.

### 6.3 `submit_data`

The direct data API gains an optional fourth argument:

```perl
$session->submit_data($stream_id, $data, $eof, $no_end_stream);
```

The argument defaults to false. Existing three-argument calls behave exactly
as before. The provider stores the value until the supplied data is fully
consumed, so a partial read never reports EOF or NO_END_STREAM before the
remainder is sent. As with callback returns, `no_end_stream` has no effect when
EOF is false.

## 7. XS design

### 7.1 Shared header marshaling

The four existing request/response code paths duplicate conversion from a
Perl array of `[name, value]` pairs into `nghttp2_nv`. A private static helper
will centralize that conversion and be used by the existing paths plus
`_submit_trailer_xs`.

The helper will:

- calculate the exact array length;
- return a safe `NULL`/zero-length representation for `[]`;
- point at Perl scalar bytes while the native call is in progress;
- set `NGHTTP2_NV_FLAG_NONE` for every entry; and
- leave ownership of the temporary `nghttp2_nv` array with the caller.

Because nghttp2 copies the fields during submission, freeing the temporary
array immediately after the native call is safe. Moving existing call sites
to the helper is a mechanical refactor: it must not add new validation or
change their behavior.

### 7.2 Provider state

`nghttp2_perl_data_provider` gains a boolean `no_end_stream` member for the
direct `submit_data` path. Every new direct submission replaces both the EOF
and NO_END_STREAM state, preventing stale flags from leaking into later data.

Callback-produced data does not need persistent trailer state. The callback
sets the native flags for that read invocation and marks the provider EOF as
it does today.

### 7.3 Reentrant trailer submission

Calling `submit_trailer` from inside the Perl data callback is supported
because nghttp2 explicitly permits native trailer submission inside its data
read callback. The binding adds no guard that would block this use. A dedicated
test must prove that the Perl-to-XS-to-nghttp2 reentrant path produces the
correct wire sequence.

## 8. Error semantics

The binding has three error layers:

1. Perl input validation croaks before entering XS.
2. A negative return from `nghttp2_submit_trailer` croaks using the existing
   `nghttp2_submit_* failed: <nghttp2_strerror>` convention.
3. A return of `0` means queued, not transmitted or acknowledged.

No wrapper stream-state preflight is added. In particular, 0.009 does not
promise that an arbitrary positive closed or unknown stream ID fails
synchronously. The deterministic native-error test uses stream ID `0`, for
which nghttp2 documents `NGHTTP2_ERR_INVALID_ARGUMENT`.

A queued non-DATA frame can later be rejected by nghttp2. Observing that class
of failure requires `nghttp2_on_frame_not_send_callback`. Binding that callback
is useful general observability work, but it is not trailer-specific and is
deferred from 0.009.

Existing callback exception behavior is unchanged.

## 9. Receive-side header category

`on_header` continues to deliver name/value pairs using its current positional
arguments. `on_begin_headers` also keeps its current signature. This avoids
breaking callbacks written with exact Perl signatures.

For HEADERS frames only, the hash passed to `on_frame_recv` gains:

```perl
headers_category => $frame->headers.cat
```

The value is one of:

- `NGHTTP2_HCAT_REQUEST`
- `NGHTTP2_HCAT_RESPONSE`
- `NGHTTP2_HCAT_PUSH_RESPONSE`
- `NGHTTP2_HCAT_HEADERS`

The key is absent on non-HEADERS frames.

The binding does not expose `is_trailer`. On a server,
`NGHTTP2_HCAT_HEADERS` after the initial request identifies a subsequent
HEADERS block such as request trailers. On a client, the same category can
also describe response headers after an informational response. A generic
binding therefore cannot equate the category with trailers without applying
HTTP message sequencing.

Consumers can accumulate fields during `on_header`, then classify the
completed block from `on_frame_recv`.

## 10. Constants

The following native header-category constants will be XS functions, members
of `@EXPORT_OK`, and members of a new `:header_categories` export tag:

- `NGHTTP2_HCAT_REQUEST`
- `NGHTTP2_HCAT_RESPONSE`
- `NGHTTP2_HCAT_PUSH_RESPONSE`
- `NGHTTP2_HCAT_HEADERS`

All RFC 9113 HTTP/2 wire error codes will be exported under a new
`:http2_errors` tag, distinct from the existing negative nghttp2 library-error
`:errors` tag:

- `NGHTTP2_NO_ERROR`
- `NGHTTP2_PROTOCOL_ERROR`
- `NGHTTP2_INTERNAL_ERROR`
- `NGHTTP2_FLOW_CONTROL_ERROR`
- `NGHTTP2_SETTINGS_TIMEOUT`
- `NGHTTP2_STREAM_CLOSED`
- `NGHTTP2_FRAME_SIZE_ERROR`
- `NGHTTP2_REFUSED_STREAM`
- `NGHTTP2_CANCEL`
- `NGHTTP2_COMPRESSION_ERROR`
- `NGHTTP2_CONNECT_ERROR`
- `NGHTTP2_ENHANCE_YOUR_CALM`
- `NGHTTP2_INADEQUATE_SECURITY`
- `NGHTTP2_HTTP_1_1_REQUIRED`

The focused constant audit also repairs two existing export inconsistencies:

- add `NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE` to `@EXPORT_OK` and `:errors`;
- add XS functions for the already-advertised `NGHTTP2_FLAG_PADDED` and
  `NGHTTP2_FLAG_PRIORITY`.

A test iterates over `@EXPORT_OK` and verifies that every advertised symbol is
callable.

## 11. Test strategy

### 11.1 Trailer round trip

A new `t/23-trailers.t` will create paired client and server sessions, exchange
their in-memory output, and assert the decoded behavior rather than only
inspecting handcrafted bytes.

The main scenario sends initial response HEADERS, body DATA, and trailer
HEADERS. The client verifies:

- body bytes arrive before trailer fields;
- initial response HEADERS use `NGHTTP2_HCAT_RESPONSE`;
- trailing HEADERS use `NGHTTP2_HCAT_HEADERS`;
- final DATA does not carry END_STREAM;
- trailing HEADERS carries END_STREAM;
- duplicate trailer fields retain their order;
- `on_stream_close` receives `NGHTTP2_NO_ERROR`; and
- the stream closes without GOAWAY or RST_STREAM.

Separate subtests cover:

- `submit_trailer` invoked after the final data callback returns;
- `submit_trailer` invoked from inside the final callback;
- an empty body followed by `headers => []`;
- existing two-value callbacks still putting END_STREAM on final DATA;
- `submit_data(..., 1, 1)` followed by trailers;
- the fourth `submit_data` value having no effect when EOF is false;
- malformed tuple input and pseudo-header rejection; and
- stream ID `0` producing a synchronous exception.

### 11.2 Receive regression

The existing trailer receive test in `t/17-client.t` will stop inferring
trailers from "headers received after DATA." It will collect each header block
and use `headers_category` when the corresponding HEADERS frame completes.
This also covers trailers on an empty body, where no DATA callback exists to
drive the old heuristic.

### 11.3 Constants and compatibility

`t/00-load.t` will verify the new tags and every symbol in `@EXPORT_OK`.
Existing streaming request, streaming response, and `submit_data` suites are
regression neighbors. The full distribution suite remains the release gate.

## 12. Documentation and release

The release changes are:

- bump `lib/Net/HTTP2/nghttp2.pm` to 0.009;
- add a 0.009 entry to `Changes`;
- document `submit_trailer`, the three-value callback, the fourth
  `submit_data` argument, `headers_category`, and queued-versus-sent semantics
  in `Session.pm` POD;
- document new constants and export tags in `nghttp2.pm` POD;
- add a concise trailer example to `README.md` and the main POD;
- add `t/23-trailers.t` to `MANIFEST`;
- run syntax checks, the focused tests, the full test suite, distribution
  generation, and distribution tests from a clean tree; and
- inspect the generated 0.009 archive before any upload.

The existing nghttp2 minimum of 1.57 remains sufficient; the trailer API does
not require a new library-version floor.

Publishing is a gated external step. Before CPAN upload or Git push, confirm
that 0.008 on CPAN corresponds to `aa77d62`, reconcile the unpushed local 0.008
commit with `origin/main`, verify GitHub credentials using host access, and
obtain final approval for the 0.009 archive. After upload, create and push the
`v0.009` tag and the approved branch/main state.

## 13. Acceptance criteria

The work is accepted when:

1. A server can stream a body, report EOF without END_STREAM, and submit
   trailers that arrive as trailing HEADERS with END_STREAM.
2. Both in-callback and post-callback trailer submission work.
3. Existing callback and `submit_data` callers behave unchanged.
4. Receivers can classify completed HEADERS blocks with native categories.
5. Pseudo-headers cannot be emitted by the public trailer method.
6. Immediate native errors croak, without a wrapper stream-state machine.
7. HTTP/2 wire error constants and header categories are exported.
8. Focused tests, the full suite, and distribution tests pass.
9. Version, changes, POD, README, and MANIFEST consistently describe 0.009.
10. The generated distribution is inspected and explicitly approved before
    CPAN publication.

## 14. Downstream next-steps report (no changes in this project)

This section records follow-up work discovered while designing 0.009. It does
not authorize or include edits to PAGI or PAGI::Server.

### 14.1 PAGI specification clarifications

The response-trailer section should state explicitly that:

- when `http.response.start` declares `trailers => 1`, a terminal
  `http.response.body` ends content production but does not complete the
  response;
- `http.response.trailers` is the terminal response event even when its
  `headers` list is empty;
- HTTP/2 maps that event to trailing HEADERS with END_STREAM, while preceding
  DATA must not carry END_STREAM;
- trailer names are ordinary lowercase HTTP field names and cannot be
  pseudo-headers;
- applications must only use fields whose definitions permit trailer use;
  and
- applications should not put essential metadata exclusively in trailers,
  since intermediaries can discard them.

PAGI currently has no receive event for request trailers. A separate design is
needed to decide whether to add an explicit `http.request.trailers` event, add
trailer data to the final `http.request`, or deliberately define a discard
policy. An explicit event would best preserve the distinction between the
initial header section and the trailer section, but this is a new PAGI API and
must not be decided as a side effect of the 0.009 binding release.

### 14.2 PAGI::Server outbound integration

Phase 2b should:

- require Net::HTTP2::nghttp2 0.009;
- remove the HTTP/2 `http.response.trailers` stub;
- have the final data callback return EOF plus NO_END_STREAM when trailers
  were declared;
- store a pending trailer event if flow control prevents the provider from
  reaching EOF immediately;
- submit pending trailers inside the final data callback, or submit them
  immediately when provider EOF was already observed;
- resolve the trailer send Future only after the native trailer frame has
  been queued, scheduling Future completion outside the nghttp2 callback to
  avoid reentrant application execution;
- roll sequence state back to `awaiting_trailers` if immediate submission
  fails, so the application can observe or retry the failed send;
- resolve quietly if the client disconnects, preserving PAGI's send-after-
  disconnect no-op contract;
- reuse the existing incomplete-response reset when an application promised
  but never supplied trailers;
- replace literal reset codes 2 and 8 with `NGHTTP2_INTERNAL_ERROR` and
  `NGHTTP2_CANCEL`; and
- remove the corresponding compliance limitation after behavioral tests pass.

Behavioral tests should include body plus trailers, empty trailers, HEAD
discard, undeclared and out-of-order trailers, flow control that delays the
final provider callback, client reset while a trailer send is pending, and
HTTP/1.1 regression coverage.

### 14.3 PAGI::Server incoming request trailers

`PAGI::Server::Protocol::HTTP2::Session` currently initializes a new request
state for every incoming HEADERS frame in `on_begin_headers`, then invokes
`on_request` for every completed HEADERS frame. A trailing request HEADERS
block can therefore overwrite per-stream state and be dispatched as a second
request on the same stream.

After adopting 0.009, the server should use `headers_category` to initialize a
request only for `NGHTTP2_HCAT_REQUEST`. A subsequent
`NGHTTP2_HCAT_HEADERS` block must be handled as request trailers rather than a
new request. Until PAGI defines application-facing request-trailer semantics,
the server at least needs an explicit, tested policy that preserves stream
state and completes the request body correctly.

### 14.4 Related header validation hardening

PAGI says header names are lowercase byte strings, but PAGI::Server's shared
validator currently rejects control characters without enforcing lowercase
HTTP field-name token syntax. Trailer integration should not silently expand
that discrepancy.

A separate conformance-hardening change should make the shared validator the
single authority for non-empty lowercase field-name syntax, pseudo-header
rejection on application-provided fields, and trailer-specific restrictions.
Because stricter validation may expose nonconforming existing applications,
that work needs its own compatibility review and tests rather than being
folded into the Net::HTTP2::nghttp2 release.

## 15. Risks and mitigations

- **Perl list stack handling:** Three callback values can be reversed or
  misread if implemented with naive `POPs` calls. Tests pin every supported
  arity and both flags.
- **Zero trailers:** A zero-length `nghttp2_nv` array must not rely on allocator
  behavior. The helper returns an explicit safe zero-length representation,
  and the empty-trailer round trip proves it.
- **Partial direct data:** EOF and NO_END_STREAM must only be set after all
  submitted bytes are consumed. Provider state and a payload larger than one
  read pin this behavior.
- **Reentrant native submission:** The in-callback test proves the use nghttp2
  documents as supported.
- **False synchronous-error promises:** Tests use stream ID `0` and docs define
  success as queued, avoiding wrapper policy that nghttp2 cannot reliably
  provide.
- **Receive misclassification:** Native categories are exposed instead of an
  unreliable `is_trailer` guess.
- **Release-state drift:** The implementation work map and CPAN/Git state are
  reconfirmed before branching, pushing, tagging, or uploading.
