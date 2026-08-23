# HTTP/2 Trailer Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Release Net::HTTP2::nghttp2 0.009 with standards-compliant HTTP/2 response-trailer transmission, an expressive end-of-data contract, reliable trailer classification on receipt, and named HTTP/2 error constants.

**Architecture:** Keep nghttp2 as the HTTP/2 state machine. Add one thin, validated Perl method for `nghttp2_submit_trailer`, teach both data-provider entry points to express `EOF | NO_END_STREAM`, and expose `frame->headers.cat` so consumers can identify later header blocks without guessing from DATA order. Reuse one XS name/value marshaler across request, response, and trailer submission; do not add a Perl-side stream state machine.

**Tech Stack:** Perl 5 / XS, libnghttp2 C API (repository minimum 1.57.0), ExtUtils::MakeMaker, Test::More, CPAN distribution tooling.

**Spec:** [`docs/superpowers/specs/2026-08-23-http2-trailer-support-design.md`](../specs/2026-08-23-http2-trailer-support-design.md)

## Global Constraints

Before changing implementation files, invoke `superpowers:using-git-worktrees` and create an isolated feature worktree from the commit containing this plan. Use branch `feat/http2-trailers-0.009` unless that name already exists. Preserve the user-owned untracked `Net-HTTP2-nghttp2-0.008.tar.gz` in the original checkout.

Record and reconfirm this work map at execution start, after any scope change, and before any push:

| Repository | Path | Ticket / scope | Branch and base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| Net::HTTP2::nghttp2 | `/Users/jnapiorkowski/Desktop/PAGI-Project/Net-HTTP2-nghttp2` or its isolated worktree | 0.009 HTTP/2 trailer support | `feat/http2-trailers-0.009`, based on the commit containing this plan and design | XS, Perl API, tests, documentation, release metadata | CPAN distribution | feature branch and `v0.009` tag on this repository's `origin`, only after approval |
| PAGI specification | `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI` | downstream clarification report | read-only; record current branch and commit | none | none in this work | none |
| PAGI::Server | `/Users/jnapiorkowski/Desktop/PAGI-Tools/PAGI-Server` | downstream integration report | read-only; record current branch and commit | none | none in this work | none |

Global rules for every task:

- Keep the distribution target at 0.009, `MIN_PERL_VERSION => '5.016'`, and the existing libnghttp2 minimum of 1.57.0; this feature needs no dependency-floor increase.
- Use `superpowers:test-driven-development`: add the failing assertion first, run it and observe the expected failure, then implement the smallest change that passes.
- Do not edit either PAGI repository. Their recommendations appear in the final section of this plan.
- Keep existing one- and two-value data callback returns and existing three-argument `submit_data` calls behaviorally unchanged.
- Do not preflight stream state in Perl, maintain a second stream lifecycle model, or add `on_frame_not_send` in 0.009.
- Do not add a PAGI request-trailer event, delivery-confirmation callback, automatic trailer-field policy, or Perl-side header-name normalization in this distribution change.
- Croak only for Perl input errors or an immediate negative return from nghttp2. A zero return means the frame was queued, not written to the network.
- Run the named focused test after each red/green cycle and commit after each task's verification passes.

---

## File structure

| File | Responsibility in this change |
| --- | --- |
| `nghttp2.xs` | Native constants, received frame metadata, data-provider state/flags, shared Perl-header marshaling, and the `nghttp2_submit_trailer` binding |
| `lib/Net/HTTP2/nghttp2/Session.pm` | Public `submit_trailer` validation, callback/API documentation, and existing high-level session conventions |
| `lib/Net/HTTP2/nghttp2.pm` | Export lists/tags, distribution version, and constant documentation |
| `t/00-load.t` | Exhaustive advertised-constant and export-tag audit |
| `t/17-client.t` | Receive-side classification of initial and later HEADERS blocks |
| `t/23-trailers.t` | Paired client/server wire tests for callback EOF, `submit_data`, trailer ordering, errors, empty cases, and reentrant submission |
| `Changes`, `README.md`, `MANIFEST` | Release notes, concise user example, and CPAN payload inventory |

The existing large XS file remains the native binding boundary; this release does not introduce a new C/XS compilation unit. The new trailer test owns the end-to-end session harness instead of spreading paired-session behavior across unrelated test files.

## Implementation tasks

### Task 1: Complete and organize the constant surface

**Files:**

- Modify: `t/00-load.t`
- Modify: `nghttp2.xs` in the constant XSUB section, currently around lines 480-635
- Modify: `lib/Net/HTTP2/nghttp2.pm` in `@EXPORT_OK` and `%EXPORT_TAGS`, currently around lines 18-58

**Produces:** Every symbol advertised through `@EXPORT_OK` is callable; HTTP/2 wire errors are available through `:http2_errors`; header categories are available through `:header_categories`; the negative libnghttp2 errors remain under `:errors`.

**Interfaces:**

- Consumes: existing zero-argument constant XSUB convention and Exporter state in `@EXPORT_OK` / `%EXPORT_TAGS`.
- Produces: callable `NGHTTP2_*()` functions, `@{ $EXPORT_TAGS{http2_errors} }`, and `@{ $EXPORT_TAGS{header_categories} }` for Tasks 2-6.

- [ ] **Step 1: Write the failing export audit**

Extend `t/00-load.t` with exact expected groups and a callable-symbol audit:

```perl
my @http2_error_names = qw(
    NGHTTP2_NO_ERROR
    NGHTTP2_PROTOCOL_ERROR
    NGHTTP2_INTERNAL_ERROR
    NGHTTP2_FLOW_CONTROL_ERROR
    NGHTTP2_SETTINGS_TIMEOUT
    NGHTTP2_STREAM_CLOSED
    NGHTTP2_FRAME_SIZE_ERROR
    NGHTTP2_REFUSED_STREAM
    NGHTTP2_CANCEL
    NGHTTP2_COMPRESSION_ERROR
    NGHTTP2_CONNECT_ERROR
    NGHTTP2_ENHANCE_YOUR_CALM
    NGHTTP2_INADEQUATE_SECURITY
    NGHTTP2_HTTP_1_1_REQUIRED
);

my @header_category_names = qw(
    NGHTTP2_HCAT_REQUEST
    NGHTTP2_HCAT_RESPONSE
    NGHTTP2_HCAT_PUSH_RESPONSE
    NGHTTP2_HCAT_HEADERS
);

my @library_error_names = qw(
    NGHTTP2_ERR_WOULDBLOCK
    NGHTTP2_ERR_CALLBACK_FAILURE
    NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE
    NGHTTP2_ERR_DEFERRED
);

is_deeply(
    [sort @{ $Net::HTTP2::nghttp2::EXPORT_TAGS{errors} }],
    [sort @library_error_names],
    ':errors contains the callback/library return errors',
);

is_deeply(
    [sort @{ $Net::HTTP2::nghttp2::EXPORT_TAGS{http2_errors} }],
    [sort @http2_error_names],
    ':http2_errors contains every HTTP/2 wire error code',
);

is_deeply(
    [sort @{ $Net::HTTP2::nghttp2::EXPORT_TAGS{header_categories} }],
    [sort @header_category_names],
    ':header_categories contains every nghttp2 header category',
);

for my $name (@Net::HTTP2::nghttp2::EXPORT_OK) {
    ok(Net::HTTP2::nghttp2->can($name), "$name is callable");
}

is(Net::HTTP2::nghttp2::NGHTTP2_INTERNAL_ERROR(), 2, 'INTERNAL_ERROR has its RFC value');
is(Net::HTTP2::nghttp2::NGHTTP2_CANCEL(), 8, 'CANCEL has its RFC value');
```

Keep the existing load/version assertions and replace a fixed test count with `done_testing` if necessary.

- [ ] **Step 2: Run the test to verify the red state**

Run:

```bash
prove -lv t/00-load.t
```

Expected: failure because the two tags and wire-error/header-category functions do not exist, and because `NGHTTP2_FLAG_PADDED` and `NGHTTP2_FLAG_PRIORITY` are advertised but not callable.

- [ ] **Step 3: Add the missing XS constant functions**

Keep the existing `NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE()` XSUB; it is already bound natively and needs only the Perl export change in Step 4. Add the missing flag, wire-error, and header-category functions as ordinary zero-argument integer XSUBs. The exact blocks are:

```xs
int
NGHTTP2_FLAG_PADDED()
    CODE:
        RETVAL = NGHTTP2_FLAG_PADDED;
    OUTPUT:
        RETVAL

int
NGHTTP2_FLAG_PRIORITY()
    CODE:
        RETVAL = NGHTTP2_FLAG_PRIORITY;
    OUTPUT:
        RETVAL

int
NGHTTP2_NO_ERROR()
    CODE:
        RETVAL = NGHTTP2_NO_ERROR;
    OUTPUT:
        RETVAL

int
NGHTTP2_PROTOCOL_ERROR()
    CODE:
        RETVAL = NGHTTP2_PROTOCOL_ERROR;
    OUTPUT:
        RETVAL

int
NGHTTP2_INTERNAL_ERROR()
    CODE:
        RETVAL = NGHTTP2_INTERNAL_ERROR;
    OUTPUT:
        RETVAL

int
NGHTTP2_FLOW_CONTROL_ERROR()
    CODE:
        RETVAL = NGHTTP2_FLOW_CONTROL_ERROR;
    OUTPUT:
        RETVAL

int
NGHTTP2_SETTINGS_TIMEOUT()
    CODE:
        RETVAL = NGHTTP2_SETTINGS_TIMEOUT;
    OUTPUT:
        RETVAL

int
NGHTTP2_STREAM_CLOSED()
    CODE:
        RETVAL = NGHTTP2_STREAM_CLOSED;
    OUTPUT:
        RETVAL

int
NGHTTP2_FRAME_SIZE_ERROR()
    CODE:
        RETVAL = NGHTTP2_FRAME_SIZE_ERROR;
    OUTPUT:
        RETVAL

int
NGHTTP2_REFUSED_STREAM()
    CODE:
        RETVAL = NGHTTP2_REFUSED_STREAM;
    OUTPUT:
        RETVAL

int
NGHTTP2_CANCEL()
    CODE:
        RETVAL = NGHTTP2_CANCEL;
    OUTPUT:
        RETVAL

int
NGHTTP2_COMPRESSION_ERROR()
    CODE:
        RETVAL = NGHTTP2_COMPRESSION_ERROR;
    OUTPUT:
        RETVAL

int
NGHTTP2_CONNECT_ERROR()
    CODE:
        RETVAL = NGHTTP2_CONNECT_ERROR;
    OUTPUT:
        RETVAL

int
NGHTTP2_ENHANCE_YOUR_CALM()
    CODE:
        RETVAL = NGHTTP2_ENHANCE_YOUR_CALM;
    OUTPUT:
        RETVAL

int
NGHTTP2_INADEQUATE_SECURITY()
    CODE:
        RETVAL = NGHTTP2_INADEQUATE_SECURITY;
    OUTPUT:
        RETVAL

int
NGHTTP2_HTTP_1_1_REQUIRED()
    CODE:
        RETVAL = NGHTTP2_HTTP_1_1_REQUIRED;
    OUTPUT:
        RETVAL

int
NGHTTP2_HCAT_REQUEST()
    CODE:
        RETVAL = NGHTTP2_HCAT_REQUEST;
    OUTPUT:
        RETVAL

int
NGHTTP2_HCAT_RESPONSE()
    CODE:
        RETVAL = NGHTTP2_HCAT_RESPONSE;
    OUTPUT:
        RETVAL

int
NGHTTP2_HCAT_PUSH_RESPONSE()
    CODE:
        RETVAL = NGHTTP2_HCAT_PUSH_RESPONSE;
    OUTPUT:
        RETVAL

int
NGHTTP2_HCAT_HEADERS()
    CODE:
        RETVAL = NGHTTP2_HCAT_HEADERS;
    OUTPUT:
        RETVAL
```

Do not hardcode numeric values in Perl or C.

- [ ] **Step 4: Update Perl exports without mixing error domains**

Add all XSUB names from Step 3 plus `NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE` to `@EXPORT_OK`. Add `NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE` to the existing `errors` tag. Define the two new tags exactly:

```perl
http2_errors => [qw(
    NGHTTP2_NO_ERROR NGHTTP2_PROTOCOL_ERROR NGHTTP2_INTERNAL_ERROR
    NGHTTP2_FLOW_CONTROL_ERROR NGHTTP2_SETTINGS_TIMEOUT
    NGHTTP2_STREAM_CLOSED NGHTTP2_FRAME_SIZE_ERROR
    NGHTTP2_REFUSED_STREAM NGHTTP2_CANCEL NGHTTP2_COMPRESSION_ERROR
    NGHTTP2_CONNECT_ERROR NGHTTP2_ENHANCE_YOUR_CALM
    NGHTTP2_INADEQUATE_SECURITY NGHTTP2_HTTP_1_1_REQUIRED
)],
header_categories => [qw(
    NGHTTP2_HCAT_REQUEST NGHTTP2_HCAT_RESPONSE
    NGHTTP2_HCAT_PUSH_RESPONSE NGHTTP2_HCAT_HEADERS
)],
```

Leave the existing `errors` tag dedicated to negative `NGHTTP2_ERR_*` return codes.

- [ ] **Step 5: Build and run the focused test**

Run:

```bash
perl Makefile.PL
make
prove -lv t/00-load.t
git diff --check
```

Expected: all assertions pass and every `@EXPORT_OK` entry is callable.

- [ ] **Step 6: Commit the constant surface**

Commit:

```bash
git add nghttp2.xs lib/Net/HTTP2/nghttp2.pm t/00-load.t
git commit -m "feat: export HTTP/2 error and header constants"
```

### Task 2: Expose the received HEADERS category

**Files:**

- Modify: `t/17-client.t` in the existing response-trailer subtest, currently around lines 472-548
- Modify: `nghttp2.xs` in `perl_on_frame_recv_callback`, currently around lines 370-397

**Produces:** `on_frame_recv` includes `headers_category` for HEADERS frames only. Callers can distinguish an initial response (`NGHTTP2_HCAT_RESPONSE`) from later ordinary header blocks (`NGHTTP2_HCAT_HEADERS`) without treating every post-DATA header as a trailer.

**Interfaces:**

- Consumes: `NGHTTP2_HCAT_RESPONSE()` and `NGHTTP2_HCAT_HEADERS()` from Task 1; existing callback signature `on_frame_recv => sub { my ($frame_hashref) = @_; return 0 }`.
- Produces: optional integer `$frame_hashref->{headers_category}` when and only when `$frame_hashref->{type}` is HEADERS.

- [ ] **Step 1: Replace the order heuristic with header-block classification**

In the existing trailer receive test in `t/17-client.t`, collect one block per `on_begin_headers`, collect its name/value pairs through `on_header`, and finalize it in `on_frame_recv`. The core assertions must be:

Import `NGHTTP2_HCAT_RESPONSE` and `NGHTTP2_HCAT_HEADERS` from Net::HTTP2::nghttp2 at the top of the test; continue using `FRAME_HEADERS` from `Test::HTTP2::Frame` for the wire frame type.

```perl
my @header_blocks;
my @current_headers;

on_begin_headers => sub {
    @current_headers = ();
    return 0;
},
on_header => sub {
    my (undef, $name, $value) = @_;
    push @current_headers, [$name, $value];
    return 0;
},
on_frame_recv => sub {
    my ($frame) = @_;
    if ($frame->{type} == FRAME_HEADERS) {
        push @header_blocks, {
            category => $frame->{headers_category},
            headers  => [map { [@$_] } @current_headers],
        };
    }
    return 0;
},
```

After feeding the fixture bytes, assert:

```perl
is($header_blocks[0]{category}, NGHTTP2_HCAT_RESPONSE, 'initial block is a response');
is($header_blocks[-1]{category}, NGHTTP2_HCAT_HEADERS, 'later block is ordinary trailing HEADERS');
ok(
    scalar(grep { $_->[0] eq 'x-checksum' } @{ $header_blocks[-1]{headers} }),
    'trailer field belongs to the later header block',
);
```

Do not depend on DATA having arrived before the trailer classification; an empty response body must remain classifiable.

- [ ] **Step 2: Run the test to verify the red state**

Run:

```bash
prove -lv t/17-client.t
```

Expected: the category assertions fail because `headers_category` is absent.

- [ ] **Step 3: Add the frame-specific hash field**

In `perl_on_frame_recv_callback`, after storing the common frame fields, add:

```c
if (frame->hd.type == NGHTTP2_HEADERS) {
    hv_store(args, "headers_category", 16,
             newSViv(frame->headers.cat), 0);
}
```

Do not add this key to DATA, SETTINGS, RST_STREAM, GOAWAY, or other frame hashes. Do not change the positional arguments of `on_begin_headers` or `on_header`.

- [ ] **Step 4: Run focused and neighboring tests**

Run:

```bash
make
prove -lv t/17-client.t t/00-load.t
git diff --check
```

Expected: the existing receive tests pass and the trailer fixture records `HCAT_RESPONSE` followed by `HCAT_HEADERS`.

- [ ] **Step 5: Commit receive classification**

Commit:

```bash
git add nghttp2.xs t/17-client.t
git commit -m "feat: expose received HEADERS category"
```

### Task 3: Extend callback-driven EOF without ending the stream

**Files:**

- Create: `t/23-trailers.t`
- Modify: `nghttp2.xs` in `perl_data_source_read_callback`, currently around lines 116-244

**Produces:** A streaming data callback may return `($chunk, $eof, $no_end_stream)`. When both flags are true, the final DATA is marked `EOF | NO_END_STREAM`, leaving the stream open for trailing HEADERS. One- and two-value returns remain unchanged.

**Interfaces:**

- Consumes: existing streaming callback input `($stream_id, $max_length, $optional_user_data)` and constants from Task 1.
- Produces: optional callback return `($chunk, $eof, $no_end_stream)` where the third value is effective only when `$eof` is true; `undef` and empty-list deferral remain unchanged.

- [ ] **Step 1: Create the in-memory session-pair test harness**

Start `t/23-trailers.t` with strict/warnings, Test::More, the module's frame/flag/error constants, and these deterministic helpers:

```perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Net::HTTP2::nghttp2 qw(
    NGHTTP2_CANCEL NGHTTP2_NO_ERROR
    NGHTTP2_HCAT_RESPONSE NGHTTP2_HCAT_HEADERS
);
use Net::HTTP2::nghttp2::Session;
use Test::HTTP2::Frame qw(FRAME_DATA FRAME_HEADERS FLAG_END_STREAM);

sub pump_sessions {
    my ($client, $server) = @_;

    for my $round (1 .. 100) {
        my $moved = 0;

        my $client_bytes = $client->mem_send;
        if (defined($client_bytes) && length($client_bytes)) {
            $server->mem_recv($client_bytes);
            $moved = 1;
        }

        my $server_bytes = $server->mem_send;
        if (defined($server_bytes) && length($server_bytes)) {
            $client->mem_recv($server_bytes);
            $moved = 1;
        }

        return unless $moved;
    }

    die "session pump did not become idle";
}

sub new_pair {
    my (%args) = @_;
    my $server_stream_id;

    my $server = Net::HTTP2::nghttp2::Session->new_server(
        callbacks => {
            on_begin_headers => sub { return 0 },
            on_header        => sub { return 0 },
            on_frame_recv    => sub {
                my ($frame) = @_;
                if ($frame->{type} == FRAME_HEADERS && $frame->{stream_id} > 0) {
                    $server_stream_id = $frame->{stream_id};
                }
                return 0;
            },
        },
    );

    my $client = Net::HTTP2::nghttp2::Session->new_client(
        callbacks => {
            on_begin_headers   => $args{on_begin_headers} || sub { return 0 },
            on_header          => $args{on_header} || sub { return 0 },
            on_frame_recv      => $args{on_frame_recv} || sub { return 0 },
            on_data_chunk_recv => $args{on_data_chunk_recv} || sub { return 0 },
            on_stream_close    => $args{on_stream_close} || sub { return 0 },
        },
    );

    $client->send_connection_preface;
    $server->send_connection_preface;
    pump_sessions($client, $server);

    my $client_stream_id = $client->submit_request(
        method    => 'GET',
        scheme    => 'https',
        authority => 'example.test',
        path      => '/trailers',
    );
    pump_sessions($client, $server);

    die "server did not receive the request stream"
        unless defined $server_stream_id;

    return ($client, $server, $client_stream_id, $server_stream_id);
}
```

If the constructors in the current test suite require callback keys not shown here, include those keys as no-op callbacks; do not change the observable behavior of the helper.

- [ ] **Step 2: Add the red three-state callback test**

Add the subtest that verifies the new signal without relying on trailer submission yet:

```perl
subtest 'callback EOF can leave the stream open' => sub {
    my (@data_frames, @closed, $body);
    my ($client, $server, $client_stream_id, $stream_id) = new_pair(
        on_data_chunk_recv => sub {
            my (undef, $data) = @_;
            $body .= $data;
            return 0;
        },
        on_frame_recv => sub {
            my ($frame) = @_;
            push @data_frames, {%$frame} if $frame->{type} == FRAME_DATA;
            return 0;
        },
        on_stream_close => sub {
            push @closed, [@_];
            return 0;
        },
    );

    my $called = 0;
    $server->submit_response(
        $stream_id,
        status  => 200,
        body    => sub {
            return undef if $called++;
            return ('body', 1, 1);
        },
    );
    pump_sessions($client, $server);

    is($body, 'body', 'the first callback value is still the data chunk');
    ok(@data_frames, 'DATA arrived');
    ok(
        !grep { $_->{flags} & FLAG_END_STREAM } @data_frames,
        'final DATA does not carry END_STREAM',
    );
    is(scalar @closed, 0, 'stream remains open for a later header block');

    $server->submit_rst_stream($stream_id, NGHTTP2_CANCEL);
    pump_sessions($client, $server);
};
```

- [ ] **Step 3: Add the legacy two-value regression test**

Add the compatibility subtest:

```perl
subtest 'legacy two-value callback still ends the stream' => sub {
    my (@data_frames, @closed, $body);
    my ($client, $server, $client_stream_id, $stream_id) = new_pair(
        on_data_chunk_recv => sub {
            my (undef, $data) = @_;
            $body .= $data;
            return 0;
        },
        on_frame_recv => sub {
            my ($frame) = @_;
            push @data_frames, {%$frame} if $frame->{type} == FRAME_DATA;
            return 0;
        },
        on_stream_close => sub {
            push @closed, [@_];
            return 0;
        },
    );

    $server->submit_response(
        $stream_id,
        status  => 200,
        body    => sub { return ('legacy', 1) },
    );
    pump_sessions($client, $server);

    is($body, 'legacy', 'legacy data is unchanged');
    ok(
        scalar(grep { $_->{flags} & FLAG_END_STREAM } @data_frames),
        'legacy EOF still ends the stream',
    );
    is(scalar @closed, 1, 'legacy stream closes normally');
};
```

End the file with `done_testing`.

- [ ] **Step 4: Add the callback arity and non-EOF compatibility test**

Add a callback-specific test that covers the one-, two-, and three-value arities and proves a true third value has no effect until EOF itself is true:

```perl
subtest 'callback arities remain compatible and no_end_stream waits for EOF' => sub {
    my (@data_frames, @closed);
    my $body = '';
    my ($client, $server, $client_stream_id, $stream_id) = new_pair(
        on_data_chunk_recv => sub {
            my (undef, $data) = @_;
            $body .= $data;
            return 0;
        },
        on_frame_recv => sub {
            my ($frame) = @_;
            push @data_frames, {%$frame} if $frame->{type} == FRAME_DATA;
            return 0;
        },
        on_stream_close => sub {
            push @closed, [@_];
            return 0;
        },
    );

    my $call = 0;
    $server->submit_response(
        $stream_id,
        status => 200,
        body   => sub {
            return 'one' if $call++ == 0;
            return ('middle', 0, 1) if $call == 2;
            return ('last', 1);
        },
    );
    pump_sessions($client, $server);

    is($body, 'onemiddlelast', 'one-, three-, and two-value chunks arrive');
    ok(
        $data_frames[-1]{flags} & FLAG_END_STREAM,
        'later legacy EOF still ends DATA',
    );
    is_deeply(\@closed, [[$client_stream_id, NGHTTP2_NO_ERROR]], 'stream closes normally');
};
```

Keep `done_testing` as the final statement in the file.

- [ ] **Step 5: Run the new test to verify the red state**

Run:

```bash
make
prove -lv t/23-trailers.t
```

Expected: the first subtest fails. With the current `POP` logic, the third value is not safely interpreted as a distinct flag and/or the final DATA carries `END_STREAM`. The legacy subtest must continue to pass.

- [ ] **Step 6: Read return values by position and set both data flags**

In the callback branch of `perl_data_source_read_callback`, stop using `POPs` to assign values by reverse stack order. Replace the result-handling block after `SPAGAIN` with this positional extraction and common stack cleanup:

```c
if (SvTRUE(ERRSV)) {
    warn("nghttp2 data provider callback error: %s", SvPV_nolen(ERRSV));
    ret = NGHTTP2_ERR_CALLBACK_FAILURE;
} else if (count == 0) {
    dp->deferred = 1;
    ret = NGHTTP2_ERR_DEFERRED;
} else {
    SV **return_values = SP - count + 1;
    SV *data_sv = return_values[0];
    SV *eof_sv = count >= 2 ? return_values[1] : NULL;
    SV *no_end_stream_sv = count >= 3 ? return_values[2] : NULL;

    if (!SvOK(data_sv)) {
        dp->deferred = 1;
        ret = NGHTTP2_ERR_DEFERRED;
    } else {
        STRLEN data_len;
        const char *data_ptr = SvPVbyte(data_sv, data_len);

        if (data_len > length) {
            data_len = length;
        }
        if (data_len > 0) {
            memcpy(buf, data_ptr, data_len);
        }
        ret = (ssize_t)data_len;

        if (eof_sv && SvTRUE(eof_sv)) {
            *data_flags |= NGHTTP2_DATA_FLAG_EOF;
            dp->eof = 1;
            if (no_end_stream_sv && SvTRUE(no_end_stream_sv)) {
                *data_flags |= NGHTTP2_DATA_FLAG_NO_END_STREAM;
            }
        }

        if (data_len == 0 && !dp->eof) {
            dp->deferred = 1;
            ret = NGHTTP2_ERR_DEFERRED;
        }
    }
}

if (count > 0) {
    SP -= count;
}
PUTBACK;
FREETMPS;
LEAVE;
return ret;
```

The third value has no effect unless `$eof` is true. Values after the third are discarded by `SP -= count`; do not leave them on the Perl stack.

- [ ] **Step 7: Verify backward compatibility**

Run:

```bash
make
prove -lv t/23-trailers.t t/02-streaming.t t/20-streaming-request.t
git diff --check
```

Expected: the new open-stream test and all legacy streaming tests pass.

- [ ] **Step 8: Commit the callback contract**

Commit:

```bash
git add nghttp2.xs t/23-trailers.t
git commit -m "feat: support data EOF without END_STREAM"
```

### Task 4: Extend direct `submit_data` with the same terminal state

**Files:**

- Modify: `t/23-trailers.t`
- Modify: `nghttp2.xs` in `perl_data_provider`, direct-data branches of `perl_data_source_read_callback`, and `submit_data`, currently around lines 14-20, 138-174, and 1171-1210

**Produces:** `submit_data($stream_id, $data, $eof, $no_end_stream)` supports the same EOF-without-END_STREAM state. The fourth argument defaults to false; it has no effect when `$eof` is false.

**Interfaces:**

- Consumes: `nghttp2_perl_data_provider` and its read callback from Task 3.
- Produces: XS method `submit_data(SV *self, int32_t stream_id, SV *data, int eof, int no_end_stream = 0)`; all existing three-argument Perl calls remain valid.

- [ ] **Step 1: Add red tests for the fourth argument**

Add a subtest that deliberately exceeds a typical single HTTP/2 DATA frame so the stored flag survives partial reads:

```perl
subtest 'submit_data can finish content without ending the stream' => sub {
    my (@data_frames, @closed, $body);
    my ($client, $server, $client_stream_id, $stream_id) = new_pair(
        on_data_chunk_recv => sub {
            my (undef, $data) = @_;
            $body .= $data;
            return 0;
        },
        on_frame_recv => sub {
            my ($frame) = @_;
            push @data_frames, {%$frame} if $frame->{type} == FRAME_DATA;
            return 0;
        },
        on_stream_close => sub {
            push @closed, [@_];
            return 0;
        },
    );

    $server->submit_response(
        $stream_id,
        status  => 200,
        body    => sub { return undef },
    );
    pump_sessions($client, $server);

    my $payload = 'x' x 32768;
    $server->submit_data($stream_id, $payload, 1, 1);
    pump_sessions($client, $server);

    is($body, $payload, 'all direct data is delivered across partial reads');
    ok(@data_frames > 1, 'payload spans more than one DATA frame');
    ok(
        !grep { $_->{flags} & FLAG_END_STREAM } @data_frames,
        'fourth argument suppresses END_STREAM at actual EOF',
    );
    is(scalar @closed, 0, 'stream remains open');

    $server->submit_rst_stream($stream_id, NGHTTP2_CANCEL);
    pump_sessions($client, $server);
};
```

- [ ] **Step 2: Add the non-EOF compatibility test**

Add a second subtest that proves the fourth value is ignored without EOF and the three-argument form is unchanged:

```perl
subtest 'no_end_stream is ignored until EOF' => sub {
    my (@data_frames, @closed);
    my $body = '';
    my ($client, $server, $client_stream_id, $stream_id) = new_pair(
        on_data_chunk_recv => sub {
            my (undef, $data) = @_;
            $body .= $data;
            return 0;
        },
        on_frame_recv => sub {
            my ($frame) = @_;
            push @data_frames, {%$frame} if $frame->{type} == FRAME_DATA;
            return 0;
        },
        on_stream_close => sub {
            push @closed, [@_];
            return 0;
        },
    );

    $server->submit_response(
        $stream_id,
        status => 200,
        body   => sub { return undef },
    );
    pump_sessions($client, $server);

    $server->submit_data($stream_id, 'first', 0, 1);
    pump_sessions($client, $server);
    is($body, 'first', 'nonterminal direct data arrives');
    ok(
        !grep { $_->{flags} & FLAG_END_STREAM } @data_frames,
        'no END_STREAM is introduced without EOF',
    );
    is(scalar @closed, 0, 'stream remains open after nonterminal data');

    @data_frames = ();
    $server->submit_data($stream_id, 'last', 1);
    pump_sessions($client, $server);
    is($body, 'firstlast', 'legacy three-argument call sends the final data');
    ok(
        scalar(grep { $_->{flags} & FLAG_END_STREAM } @data_frames),
        'legacy EOF still puts END_STREAM on DATA',
    );
    is_deeply(\@closed, [[$client_stream_id, NGHTTP2_NO_ERROR]], 'stream closes normally');
};
```

- [ ] **Step 3: Run the test to verify the red state**

Run:

```bash
prove -lv t/23-trailers.t
```

Expected: an argument-count error for the new four-argument call.

- [ ] **Step 4: Store and consume the direct-data flag**

Add this field to `perl_data_provider`:

```c
int no_end_stream;
```

Change the XSUB signature and initialization:

```xs
int
submit_data(self, stream_id, data_sv, eof, no_end_stream = 0)
    SV *self
    int32_t stream_id
    SV *data_sv
    int eof
    int no_end_stream
```

When installing the direct buffer, store only an effective terminal flag:

```c
dp->eof = eof ? 1 : 0;
dp->no_end_stream = (eof && no_end_stream) ? 1 : 0;
```

In both direct-data EOF branches of `perl_data_source_read_callback`, add `NGHTTP2_DATA_FLAG_NO_END_STREAM` only when the stored flag is true:

```c
if (dp->eof) {
    *data_flags |= NGHTTP2_DATA_FLAG_EOF;
    if (dp->no_end_stream) {
        *data_flags |= NGHTTP2_DATA_FLAG_NO_END_STREAM;
    }
}
```

Clear `no_end_stream` when a nonterminal direct buffer is exhausted or new data is installed, so a prior call cannot leak its state into a later call.

- [ ] **Step 5: Verify new and old calls**

Run:

```bash
make
prove -lv t/23-trailers.t t/21-submit-data.t
git diff --check
```

Expected: four-argument and legacy three-argument `submit_data` tests pass.

- [ ] **Step 6: Commit the direct-data contract**

Commit:

```bash
git add nghttp2.xs t/23-trailers.t
git commit -m "feat: let submit_data reserve END_STREAM for trailers"
```

### Task 5: Bind and validate `submit_trailer`, then prove wire ordering

**Files:**

- Modify: `t/23-trailers.t`
- Modify: `lib/Net/HTTP2/nghttp2/Session.pm` after `submit_response`, currently around lines 106-146
- Modify: `nghttp2.xs` near the data-provider helpers and response/request submission XSUBs

**Produces:** Public API `$session->submit_trailer($stream_id, headers => \@pairs)`; one shared XS name/value marshaler; successful trailer transmission after final body data whether queued after the callback or from inside it; deterministic failure for stream ID zero.

**Interfaces:**

- Consumes: `headers_category` from Task 2, callback triple from Task 3, direct-data fourth argument from Task 4, and native `nghttp2_submit_trailer(session, stream_id, nva, nvlen)`.
- Produces: public Perl method `submit_trailer($stream_id, headers => ArrayRef[ArrayRef[Scalar, Scalar]]) -> 0 or croak`; private XSUB `_submit_trailer_xs($stream_id, $headers_av) -> 0 or croak`; helper `perl_headers_to_nva(pTHX_ AV *, size_t *) -> nghttp2_nv *`.

- [ ] **Step 1: Add the post-callback round-trip test**

Extend the `Test::HTTP2::Frame` import in `t/23-trailers.t` with `FRAME_GOAWAY` and `FRAME_RST_STREAM`. `NGHTTP2_NO_ERROR` is already imported by the harness from Task 3. Add this subtest:

```perl
subtest 'body and trailers round trip after the callback returns' => sub {
    my (@blocks, @current, @data_frames, @terminal_frames, @closed, @events);
    my $body = '';

    my ($client, $server, $client_stream_id, $stream_id) = new_pair(
        on_begin_headers => sub {
            @current = ();
            return 0;
        },
        on_header => sub {
            my (undef, $name, $value) = @_;
            push @current, [$name, $value];
            return 0;
        },
        on_data_chunk_recv => sub {
            my (undef, $data) = @_;
            $body .= $data;
            push @events, 'data';
            return 0;
        },
        on_frame_recv => sub {
            my ($frame) = @_;
            if ($frame->{type} == FRAME_HEADERS) {
                push @blocks, {
                    category => $frame->{headers_category},
                    flags    => $frame->{flags},
                    headers  => [map { [@$_] } @current],
                };
                push @events, 'trailers'
                    if $frame->{headers_category} == NGHTTP2_HCAT_HEADERS;
            }
            push @data_frames, {%$frame} if $frame->{type} == FRAME_DATA;
            push @terminal_frames, {%$frame}
                if $frame->{type} == FRAME_GOAWAY
                || $frame->{type} == FRAME_RST_STREAM;
            return 0;
        },
        on_stream_close => sub {
            push @closed, [@_];
            return 0;
        },
    );

    $server->submit_response(
        $stream_id,
        status  => 200,
        headers => [['content-type', 'text/plain']],
        body    => sub { return ('response body', 1, 1) },
    );
    pump_sessions($client, $server);

    $server->submit_trailer(
        $stream_id,
        headers => [
            ['x-checksum', 'abc'],
            ['set-cookie', 'a=1'],
            ['set-cookie', 'b=2'],
        ],
    );
    pump_sessions($client, $server);

    is($body, 'response body', 'body arrives intact');
    is_deeply(
        [map { $_->{category} } @blocks],
        [NGHTTP2_HCAT_RESPONSE, NGHTTP2_HCAT_HEADERS],
        'initial response and trailing HEADERS have distinct categories',
    );
    is_deeply(
        $blocks[-1]{headers},
        [
            ['x-checksum', 'abc'],
            ['set-cookie', 'a=1'],
            ['set-cookie', 'b=2'],
        ],
        'trailer order and duplicate fields survive the wire',
    );
    ok(
        !grep { $_->{flags} & FLAG_END_STREAM } @data_frames,
        'DATA reserves END_STREAM for trailers',
    );
    ok($blocks[-1]{flags} & FLAG_END_STREAM, 'trailing HEADERS ends the stream');
    is_deeply(\@events, ['data', 'trailers'], 'body is observed before trailers');
    is_deeply(\@closed, [[$client_stream_id, NGHTTP2_NO_ERROR]], 'stream closes cleanly');
    is(scalar @terminal_frames, 0, 'no RST_STREAM or GOAWAY was needed');
};
```

- [ ] **Step 2: Add the reentrant scheduling test**

Add the reentrant scheduling subtest:

```perl
subtest 'trailers can be queued inside the body callback' => sub {
    my (@blocks, @current, @events, @closed);
    my ($client, $server, $client_stream_id, $stream_id) = new_pair(
        on_begin_headers => sub {
            @current = ();
            return 0;
        },
        on_header => sub {
            my (undef, $name, $value) = @_;
            push @current, [$name, $value];
            return 0;
        },
        on_data_chunk_recv => sub {
            push @events, 'data';
            return 0;
        },
        on_frame_recv => sub {
            my ($frame) = @_;
            if ($frame->{type} == FRAME_HEADERS) {
                push @blocks, {
                    category => $frame->{headers_category},
                    flags    => $frame->{flags},
                    headers  => [map { [@$_] } @current],
                };
                push @events, 'trailers'
                    if $frame->{headers_category} == NGHTTP2_HCAT_HEADERS;
            }
            return 0;
        },
        on_stream_close => sub {
            push @closed, [@_];
            return 0;
        },
    );

    my $submitted = 0;
    $server->submit_response(
        $stream_id,
        status => 200,
        body   => sub {
            if (!$submitted++) {
                $server->submit_trailer(
                    $stream_id,
                    headers => [['x-inside', 'yes']],
                );
            }
            return ('inside body', 1, 1);
        },
    );
    pump_sessions($client, $server);

    is_deeply(\@events, ['data', 'trailers'], 'reentrant submission preserves wire order');
    is($blocks[-1]{category}, NGHTTP2_HCAT_HEADERS, 'reentrant block is later HEADERS');
    is_deeply($blocks[-1]{headers}, [['x-inside', 'yes']], 'reentrant trailer arrives');
    ok($blocks[-1]{flags} & FLAG_END_STREAM, 'reentrant trailer ends the stream');
    is_deeply(\@closed, [[$client_stream_id, NGHTTP2_NO_ERROR]], 'reentrant stream closes cleanly');
};
```

- [ ] **Step 3: Add the empty-content and empty-trailer test**

Add the empty-content/empty-trailer test. It deliberately does not require nghttp2 to emit a zero-length DATA frame:

```perl
subtest 'empty body and empty trailer block still terminate' => sub {
    my (@blocks, @current, @closed);
    my ($client, $server, $client_stream_id, $stream_id) = new_pair(
        on_begin_headers => sub {
            @current = ();
            return 0;
        },
        on_header => sub {
            my (undef, $name, $value) = @_;
            push @current, [$name, $value];
            return 0;
        },
        on_frame_recv => sub {
            my ($frame) = @_;
            if ($frame->{type} == FRAME_HEADERS) {
                push @blocks, {
                    category => $frame->{headers_category},
                    flags    => $frame->{flags},
                    headers  => [map { [@$_] } @current],
                };
            }
            return 0;
        },
        on_stream_close => sub {
            push @closed, [@_];
            return 0;
        },
    );

    $server->submit_response(
        $stream_id,
        status => 200,
        body   => sub { return ('', 1, 1) },
    );
    pump_sessions($client, $server);
    $server->submit_trailer($stream_id, headers => []);
    pump_sessions($client, $server);

    is($blocks[-1]{category}, NGHTTP2_HCAT_HEADERS, 'empty trailer is later HEADERS');
    is_deeply($blocks[-1]{headers}, [], 'empty trailer block has no fields');
    ok($blocks[-1]{flags} & FLAG_END_STREAM, 'empty trailer block ends the stream');
    is_deeply(\@closed, [[$client_stream_id, NGHTTP2_NO_ERROR]], 'empty response closes normally');
};
```

- [ ] **Step 4: Add a direct `submit_data` followed by trailers test**

Add the direct-data counterpart to the callback round trip:

```perl
subtest 'submit_data can reserve END_STREAM for trailers' => sub {
    my (@blocks, @current, @data_frames, @closed);
    my $body = '';
    my ($client, $server, $client_stream_id, $stream_id) = new_pair(
        on_begin_headers => sub {
            @current = ();
            return 0;
        },
        on_header => sub {
            my (undef, $name, $value) = @_;
            push @current, [$name, $value];
            return 0;
        },
        on_data_chunk_recv => sub {
            my (undef, $data) = @_;
            $body .= $data;
            return 0;
        },
        on_frame_recv => sub {
            my ($frame) = @_;
            if ($frame->{type} == FRAME_HEADERS) {
                push @blocks, {
                    category => $frame->{headers_category},
                    flags    => $frame->{flags},
                    headers  => [map { [@$_] } @current],
                };
            }
            push @data_frames, {%$frame} if $frame->{type} == FRAME_DATA;
            return 0;
        },
        on_stream_close => sub {
            push @closed, [@_];
            return 0;
        },
    );

    $server->submit_response(
        $stream_id,
        status => 200,
        body   => sub { return undef },
    );
    pump_sessions($client, $server);
    $server->submit_data($stream_id, 'direct body', 1, 1);
    pump_sessions($client, $server);
    $server->submit_trailer(
        $stream_id,
        headers => [['x-direct', 'yes']],
    );
    pump_sessions($client, $server);

    is($body, 'direct body', 'direct data arrives before trailers');
    ok(
        !grep { $_->{flags} & FLAG_END_STREAM } @data_frames,
        'direct final DATA does not end the stream',
    );
    is($blocks[-1]{category}, NGHTTP2_HCAT_HEADERS, 'direct trailer is later HEADERS');
    is_deeply($blocks[-1]{headers}, [['x-direct', 'yes']], 'direct trailer arrives');
    ok($blocks[-1]{flags} & FLAG_END_STREAM, 'direct trailing HEADERS ends the stream');
    is_deeply(\@closed, [[$client_stream_id, NGHTTP2_NO_ERROR]], 'direct stream closes cleanly');
};
```

- [ ] **Step 5: Add field/index-specific Perl validation tests**

Add the validation subtest:

```perl
subtest 'submit_trailer validates the Perl header shape' => sub {
    my ($client, $server, $client_stream_id, $stream_id) = new_pair();
    my @cases = (
        [
            'non-array header list',
            sub { $server->submit_trailer($stream_id, headers => {}) },
            qr/submit_trailer: headers must be an array reference/,
        ],
        [
            'non-array pair',
            sub { $server->submit_trailer($stream_id, headers => ['x']) },
            qr/submit_trailer: header 0 must be a two-element array reference/,
        ],
        [
            'one-element pair',
            sub { $server->submit_trailer($stream_id, headers => [['x']]) },
            qr/submit_trailer: header 0 must be a two-element array reference/,
        ],
        [
            'undefined name',
            sub { $server->submit_trailer($stream_id, headers => [[undef, 'v']]) },
            qr/submit_trailer: header 0 name must be a defined non-reference scalar/,
        ],
        [
            'reference value',
            sub { $server->submit_trailer($stream_id, headers => [['x', []]]) },
            qr/submit_trailer: header 0 value must be a defined non-reference scalar/,
        ],
        [
            'pseudo-header',
            sub { $server->submit_trailer($stream_id, headers => [[':status', '200']]) },
            qr/submit_trailer: header 0 must not use a pseudo-header name/,
        ],
    );

    for my $case (@cases) {
        my ($label, $call, $pattern) = @$case;
        my $ok = eval {
            $call->();
            1;
        };
        ok(!$ok, "$label dies");
        like($@, $pattern, "$label reports the precise input error");
    }
};
```

- [ ] **Step 6: Add the deterministic native immediate-error test**

Add the invalid stream-ID subtest:

```perl
subtest 'stream ID zero fails immediately' => sub {
    my ($client, $server, $client_stream_id, $stream_id) = new_pair();
    my $ok = eval {
        $server->submit_trailer(0);
        1;
    };

    ok(!$ok, 'invalid stream ID dies');
    like($@, qr/nghttp2_submit_trailer failed:/, 'native error is reported');
};
```

Stream ID zero is the deterministic invalid target; do not require an arbitrary positive closed/unknown stream to fail synchronously.

- [ ] **Step 7: Run the tests to verify the red state**

Run:

```bash
prove -lv t/23-trailers.t
```

Expected: trailer subtests fail with `Can't locate object method "submit_trailer"`; tests from Tasks 3 and 4 remain green.

- [ ] **Step 8: Add the validated Perl wrapper**

Add this method to `Session.pm`:

```perl
sub submit_trailer {
    my ($self, $stream_id, %args) = @_;

    my $headers = delete($args{headers}) // [];
    croak 'submit_trailer: headers must be an array reference'
        unless ref($headers) eq 'ARRAY';

    for my $index (0 .. $#$headers) {
        my $pair = $headers->[$index];
        croak "submit_trailer: header $index must be a two-element array reference"
            unless ref($pair) eq 'ARRAY' && @$pair == 2;

        my ($name, $value) = @$pair;
        croak "submit_trailer: header $index name must be a defined non-reference scalar"
            unless defined($name) && !ref($name);
        croak "submit_trailer: header $index value must be a defined non-reference scalar"
            unless defined($value) && !ref($value);
        croak "submit_trailer: header $index must not use a pseudo-header name"
            if $name =~ /^:/;
    }

    return $self->_submit_trailer_xs($stream_id, $headers);
}
```

This wrapper preserves input order and duplicates. It treats omitted or explicitly undefined `headers` as an empty terminal trailer block. Do not normalize case, merge duplicates, or reject ordinary fields at this layer.

- [ ] **Step 9: Extract one XS name/value marshaler**

Above the data-provider read callback, add:

```c
static nghttp2_nv *perl_headers_to_nva(pTHX_ AV *headers_av,
                                       size_t *nvlen_out) {
    I32 last_index = av_len(headers_av);
    size_t nvlen = last_index < 0 ? 0 : (size_t)last_index + 1;
    nghttp2_nv *nva = NULL;
    I32 i;

    *nvlen_out = nvlen;
    if (nvlen == 0) {
        return NULL;
    }

    Newxz(nva, nvlen, nghttp2_nv);

    for (i = 0; i < (I32)nvlen; i++) {
        SV **pair = av_fetch(headers_av, i, 0);
        if (pair && SvROK(*pair) && SvTYPE(SvRV(*pair)) == SVt_PVAV) {
            AV *pair_av = (AV *)SvRV(*pair);
            SV **name_sv = av_fetch(pair_av, 0, 0);
            SV **value_sv = av_fetch(pair_av, 1, 0);

            if (name_sv && value_sv) {
                STRLEN name_len;
                STRLEN value_len;
                nva[i].name = (uint8_t *)SvPVbyte(*name_sv, name_len);
                nva[i].namelen = name_len;
                nva[i].value = (uint8_t *)SvPVbyte(*value_sv, value_len);
                nva[i].valuelen = value_len;
                nva[i].flags = NGHTTP2_NV_FLAG_NONE;
            }
        }
    }

    return nva;
}
```

Replace the four duplicated loops in `_submit_response_with_body`, `_submit_response_no_body`, `_submit_response_streaming`, and `_submit_request_xs` with:

```c
nva = perl_headers_to_nva(aTHX_ headers_av, &nvlen);
```

Remove now-unused `I32 i` declarations. Keep the existing submission order and cleanup behavior. Guard each free with `if (nva) Safefree(nva);` so an empty header AV is represented as `NULL, 0` safely.

- [ ] **Step 10: Add the private trailer XSUB**

In package `Net::HTTP2::nghttp2::Session`, add:

```xs
int
_submit_trailer_xs(self, stream_id, headers_av)
        SV *self
        int32_t stream_id
        AV *headers_av
    PREINIT:
        nghttp2_perl_session *ps;
        nghttp2_nv *nva;
        size_t nvlen;
        int rv;
    CODE:
        ps = (nghttp2_perl_session *)SvIV(SvRV(self));
        nva = perl_headers_to_nva(aTHX_ headers_av, &nvlen);

        rv = nghttp2_submit_trailer(ps->session, stream_id, nva, nvlen);

        if (nva) {
            Safefree(nva);
        }

        if (rv != 0) {
            croak("nghttp2_submit_trailer failed: %s", nghttp2_strerror(rv));
        }
        RETVAL = rv;
    OUTPUT:
        RETVAL
```

Do not look up the stream in `data_providers`, preflight its lifecycle in Perl/XS, or promise that every invalid positive stream ID is rejected at queue time. Native zero means the trailer block is accepted into nghttp2's outbound queue.

- [ ] **Step 11: Run the full trailer matrix and neighboring regression tests**

Run:

```bash
make
prove -lv t/23-trailers.t
prove -lv t/02-streaming.t t/17-client.t t/20-streaming-request.t t/21-submit-data.t
git diff --check
```

Expected: both trailer scheduling positions work; empty trailers close correctly; malformed Perl input and stream ID zero fail; existing streaming remains green.

- [ ] **Step 12: Commit trailer submission**

Commit:

```bash
git add nghttp2.xs lib/Net/HTTP2/nghttp2/Session.pm t/23-trailers.t
git commit -m "feat: submit HTTP/2 trailing HEADERS"
```

### Task 6: Document the API and prepare 0.009 release metadata

**Files:**

- Modify: `lib/Net/HTTP2/nghttp2.pm`
- Modify: `lib/Net/HTTP2/nghttp2/Session.pm`
- Modify: `README.md`
- Modify: `Changes`
- Modify: `MANIFEST`

**Produces:** Version 0.009 metadata and user-facing documentation that accurately distinguishes content EOF, stream END_STREAM, queued submission, header category, and the two error-code domains.

**Interfaces:**

- Consumes: all public signatures and observable behavior from Tasks 1-5.
- Produces: `$Net::HTTP2::nghttp2::VERSION eq '0.009'`, complete POD/README usage contracts, `Changes` entry 0.009, and `MANIFEST` membership for `t/23-trailers.t`.

- [ ] **Step 1: Bump the module version and changelog**

Change only the authoritative version in `lib/Net/HTTP2/nghttp2.pm`:

```perl
our $VERSION = '0.009';
```

Add this release entry above 0.008 in `Changes`:

```text
0.009   2026-08-23
        - Add submit_trailer() for trailing HTTP/2 HEADERS.
        - Allow streaming callbacks and submit_data() to signal content EOF
          without END_STREAM when a trailing header block will follow.
        - Expose received HEADERS categories through on_frame_recv.
        - Export HTTP/2 wire error codes and header-category constants in
          dedicated :http2_errors and :header_categories tags.
        - Complete the advertised constant bindings and add an export audit.
```

- [ ] **Step 2: Document the three-state producer contract**

In both request and response streaming callback POD, document these returns:

```text
($data, $eof_flag)
    Send data. A true EOF ends the stream, preserving pre-0.009 behavior.

($data, $eof_flag, $no_end_stream)
    Send data. When both flags are true, content production is complete but
    DATA does not carry END_STREAM, allowing submit_trailer() to queue the
    terminal HEADERS block. The third value has no effect unless EOF is true.

undef or an empty list
    Defer production until the stream is resumed or submit_data() is called.
```

Update the source comments immediately above `submit_request` and `_submit_response_streaming` to mention the optional third return value as well.

- [ ] **Step 3: Add `submit_trailer` and `submit_data` POD**

Add this public method section after `submit_response`:

```pod
=head2 submit_trailer

    $session->submit_trailer(
        $stream_id,
        headers => [
            ['x-checksum', 'abc'],
            ['set-cookie', 'a=1'],
            ['set-cookie', 'b=2'],
        ],
    );

Queue a trailing HEADERS block that ends the stream. C<headers> defaults to an
empty array reference; order and duplicate names are preserved. Trailer names
must be ordinary field names, not pseudo-header names beginning with C<:>.

Before calling this method, the data provider must finish with
C<($data, 1, 1)> or C<submit_data($stream_id, $data, 1, 1)> so the final DATA
does not consume END_STREAM. C<submit_trailer> may be called inside the data
callback or after that callback returns.

A zero return means nghttp2 accepted the trailer block into its outbound
queue. It does not mean the peer has received it. Invalid Perl input and
immediate nghttp2 submission errors throw exceptions.
```

Change the `submit_data` synopsis to:

```perl
$session->submit_data($stream_id, $data, $eof, $no_end_stream);
```

Document that the fourth argument is optional and false by default, is effective only with true EOF, and requests content completion without DATA END_STREAM so trailers can follow. Preserve the documentation of the three-argument behavior.

- [ ] **Step 4: Document receive classification and constant tags**

Change the `on_frame_recv` POD to say the common hash fields remain `type`, `flags`, `stream_id`, and `length`, and a HEADERS frame additionally contains `headers_category`. Document:

```text
NGHTTP2_HCAT_REQUEST       initial request headers
NGHTTP2_HCAT_RESPONSE      initial response headers
NGHTTP2_HCAT_PUSH_RESPONSE pushed response headers
NGHTTP2_HCAT_HEADERS       a later ordinary HEADERS block
```

Explicitly state that `HCAT_HEADERS` identifies a later block on an open stream but is not, by itself, a universal `is_trailer` boolean: informational responses and message direction/state still matter to consumers.

In `lib/Net/HTTP2/nghttp2.pm`, split the POD terminology:

- **Library error returns (`:errors`)** are negative `NGHTTP2_ERR_*` values used by API calls/callbacks.
- **HTTP/2 wire errors (`:http2_errors`)** are RFC error codes including `NGHTTP2_NO_ERROR`, `NGHTTP2_INTERNAL_ERROR`, and `NGHTTP2_CANCEL`.
- **Header categories (`:header_categories`)** are the four `NGHTTP2_HCAT_*` values above.

Mention `NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE` in the library-error list and the `PADDED`/`PRIORITY` flags in the flag list.

- [ ] **Step 5: Add concise README and parent-module examples**

After the existing streaming response example in `README.md`, and in the streaming examples of `lib/Net/HTTP2/nghttp2.pm` POD, add:

```perl
my @chunks = ('first chunk', 'final chunk');

$session->submit_response(
    $stream_id,
    status => 200,
    body   => sub {
        my $chunk = shift @chunks;
        my $last = @chunks ? 0 : 1;

        if ($last) {
            $session->submit_trailer(
                $stream_id,
                headers => [['x-checksum', 'abc']],
            );
        }

        return ($chunk, $last, $last);
    },
);
```

In both places, explain in one paragraph that the third true value reserves END_STREAM for trailing HEADERS, and that a two-value `($chunk, 1)` still ends on DATA exactly as before.

- [ ] **Step 6: Add the test to the distribution manifest**

Insert:

```text
t/23-trailers.t
```

after `t/22-rst-rate-limit.t` in `MANIFEST`. Do not add local worktree metadata, generated build products, or either design/plan document to the CPAN payload unless the maintainer separately chooses to distribute internal project documentation.

- [ ] **Step 7: Validate docs, metadata, and tests**

Run:

```bash
perl Makefile.PL
make
perl -Iblib/lib -Iblib/arch -c lib/Net/HTTP2/nghttp2.pm
perl -Iblib/lib -Iblib/arch -c lib/Net/HTTP2/nghttp2/Session.pm
podchecker lib/Net/HTTP2/nghttp2.pm
podchecker lib/Net/HTTP2/nghttp2/Session.pm
prove -lv t/00-load.t t/23-trailers.t
git diff --check
```

Expected: version 0.009 loads, both POD files are syntactically valid, and focused tests pass.

- [ ] **Step 8: Commit release metadata**

Commit:

```bash
git add Changes MANIFEST README.md lib/Net/HTTP2/nghttp2.pm lib/Net/HTTP2/nghttp2/Session.pm
git commit -m "docs: prepare Net-HTTP2-nghttp2 0.009"
```

### Task 7: Run the release-candidate verification gate

**Files:**

- Verify only: all tracked files
- Generate: `Net-HTTP2-nghttp2-0.009.tar.gz`

**Produces:** A tested 0.009 source distribution and recorded evidence suitable for the maintainer's publication decision. This task does not upload or push anything.

**Interfaces:**

- Consumes: green tracked release candidate from Tasks 1-6.
- Produces: `Net-HTTP2-nghttp2-0.009.tar.gz`, its SHA-256 digest, complete test summaries, archive inventory, and a clean tracked worktree.

- [ ] **Step 1: Reconfirm repository ownership and revisions**

From the feature worktree, record:

```bash
git status -sb
git rev-parse HEAD
git merge-base HEAD origin/main
git -C /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI status -sb
git -C /Users/jnapiorkowski/Desktop/PAGI-Project/PAGI rev-parse HEAD
git -C /Users/jnapiorkowski/Desktop/PAGI-Tools/PAGI-Server status -sb
git -C /Users/jnapiorkowski/Desktop/PAGI-Tools/PAGI-Server rev-parse HEAD
```

Expected: implementation changes exist only in Net::HTTP2::nghttp2. If architecture or ownership no longer matches the work map, stop and reconfirm scope before continuing.

- [ ] **Step 2: Run focused behavior tests**

Run:

```bash
prove -lv t/00-load.t t/17-client.t t/23-trailers.t
prove -lv t/02-streaming.t t/20-streaming-request.t t/21-submit-data.t
```

Expected: all receive classification, transmit trailer, EOF compatibility, and direct-data tests pass.

- [ ] **Step 3: Run the complete installed-build suite**

Use the repository's validated Perl toolchain; on this machine the known command is:

```bash
/bin/zsh -lc 'perlbrew use perl-5.40.0@default; perl Makefile.PL && make test'
```

Expected: the complete suite passes with no unexpected skips or new warnings. Record the test count and summary in the handoff.

- [ ] **Step 4: Build and test the distribution artifact**

Run:

```bash
/bin/zsh -lc 'perlbrew use perl-5.40.0@default; make disttest'
/bin/zsh -lc 'perlbrew use perl-5.40.0@default; make dist'
tar -tzf Net-HTTP2-nghttp2-0.009.tar.gz
```

Expected: `disttest` passes from the unpacked distribution, `t/23-trailers.t` is present in the archive, and no worktree/build metadata or 0.008 archive is nested in the 0.009 archive.

- [ ] **Step 5: Perform final static and repository checks**

Run:

```bash
git diff --check
git status --short
git log --oneline --decorate origin/main..HEAD
shasum -a 256 Net-HTTP2-nghttp2-0.009.tar.gz
```

Expected: no tracked modifications remain; the only task-generated untracked artifact is the 0.009 tarball; all planned commits are present; a SHA-256 digest is ready for approval. If verification exposes a defect, add a failing regression test, fix it, rerun the relevant focused tests and this entire gate, and commit the correction before proceeding.

### Task 8: Publish 0.009 only after an explicit release approval

**Files:**

- Publish: the verified `Net-HTTP2-nghttp2-0.009.tar.gz`
- Tag: the verified release commit as `v0.009`

**Produces:** CPAN release 0.009 and a pushed source/tag, but only after the maintainer reviews the verification evidence and explicitly authorizes external publication.

**Interfaces:**

- Consumes: the exact verified artifact, checksum, commit, and test evidence from Task 7 plus explicit maintainer approval.
- Produces: CPAN/MetaCPAN version 0.009, remote feature branch, and annotated `v0.009` tag resolving to the approved release commit.

- [ ] **Step 1: Reconcile the existing local/remote release history read-only**

Before asking for approval, verify:

```bash
git fetch origin
git log --oneline --decorate --graph --all -12
git merge-base --is-ancestor aa77d62 origin/main
git ls-remote --heads --tags origin
```

Also verify from CPAN/MetaCPAN that the published 0.008 archive corresponds to the local 0.008 source lineage. The repository started this work with `main` ahead of `origin/main`, so do not assume the Rapid Reset commit or design/plan commits are already public. Report any mismatch before publishing.

- [ ] **Step 2: Present the release evidence and request approval**

Present:

- feature branch and exact release commit;
- base and remote divergence;
- full-suite and `disttest` summaries;
- archive filename and SHA-256;
- archive content check;
- proposed CPAN upload, branch push, and annotated tag push commands.

Stop until the maintainer explicitly approves these external mutations.

- [ ] **Step 3: Authenticate and publish after approval**

With host credential access, run:

```bash
gh auth status -h github.com
cpan-upload Net-HTTP2-nghttp2-0.009.tar.gz
git tag -a v0.009 -m "Release Net::HTTP2::nghttp2 0.009"
git push origin feat/http2-trailers-0.009
git push origin v0.009
```

If the maintainer chooses a pull request or fast-forward merge rather than a direct feature-branch publication, invoke `superpowers:finishing-a-development-branch` and follow that choice; do not push `main` implicitly.

- [ ] **Step 4: Verify the public result**

Confirm the CPAN/MetaCPAN release reports version 0.009 and the uploaded archive checksum/content match the approved artifact. Confirm `origin` contains the expected feature commit and `v0.009` resolves to the release commit. Report indexing delay as a pending external state rather than re-uploading.

---

## Downstream next steps — report only in this project

No checklist item above authorizes changes to PAGI or PAGI::Server. After 0.009 is implemented and verified, hand the following integration report to those maintainers.

### PAGI specification clarifications

Recommend specifying these semantics before treating trailers as portable application behavior:

- `http.response.start` with `trailers => 1` declares that a trailer event may follow.
- The final body event ends response content but does not finish the response when trailers were declared.
- `http.response.trailers` is terminal even when its header list is empty.
- On HTTP/2, the final DATA uses content EOF without END_STREAM and the trailing HEADERS block carries END_STREAM.
- Trailer names are lowercase ordinary field names; pseudo-headers are forbidden. Applications and servers must also enforce the field restrictions defined by the applicable HTTP semantics specification, and essential routing/security metadata must not exist only in trailers.
- Request trailers need an explicit, separate PAGI contract: either a distinct request-trailer event, trailers attached to the final request-body event, or a documented discard policy. Do not infer request semantics from the response event.

### PAGI::Server outbound integration

After depending on Net::HTTP2::nghttp2 0.009:

- remove the HTTP/2 trailer stub;
- make the final body producer return `($chunk, 1, 1)` when declared trailers remain;
- queue `submit_trailer` either inside that callback or immediately after it returns, preserving DATA-before-HEADERS order under flow control;
- resolve the application trailer Future when nghttp2 accepts the block into its queue, not when bytes reach the peer, and avoid synchronously re-entering application code from the native data callback;
- roll back server-side pending-trailer state if submission throws immediately;
- treat a peer disconnect before trailer submission as the existing disconnect path, and keep the existing incomplete-response reset behavior for an application that declares trailers but never sends a terminal event;
- replace literal HTTP/2 error values such as `2` and `8` with `NGHTTP2_INTERNAL_ERROR` and `NGHTTP2_CANCEL`;
- test ordinary, empty, duplicate, callback-reentrant, flow-controlled, disconnect, and immediate-failure cases.

### PAGI::Server inbound and conformance follow-up

The current Protocol::HTTP2 receive path must not initialize or overwrite request state for every HEADERS frame. Use `NGHTTP2_HCAT_REQUEST` for initial request setup and treat later `NGHTTP2_HCAT_HEADERS` according to the future PAGI request-trailer policy. Separately harden PAGI header validation to enforce its lowercase-name requirement; the existing control-character check is not sufficient. These are downstream design/conformance changes, not part of the Net::HTTP2::nghttp2 0.009 patch.

## Completion criteria

Implementation is complete when Tasks 1-7 pass and the maintainer has received the downstream report. Release is complete only when the separately approved Task 8 publication and public verification finish. The acceptance demonstration must show a PAGI-compatible response shape can declare trailers, stream body bytes whose final DATA lacks END_STREAM, send terminal trailing HEADERS with END_STREAM, expose those fields under `NGHTTP2_HCAT_HEADERS`, and close with `NGHTTP2_NO_ERROR`.
