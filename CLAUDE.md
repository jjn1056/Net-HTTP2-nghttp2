# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Net::HTTP2::nghttp2 provides Perl XS bindings for the nghttp2 C library, enabling HTTP/2 protocol support in Perl applications. It implements RFC 9113 (HTTP/2) and RFC 7541 (HPACK) through the battle-tested nghttp2 library used by curl, Apache, and Firefox.

## Build Commands

**Use perlbrew with perl-5.40.0@default** for all build and test commands.

```bash
# Configure and build
perlbrew exec --with perl-5.40.0@default perl Makefile.PL
perlbrew exec --with perl-5.40.0@default make

# Run all tests
perlbrew exec --with perl-5.40.0@default make test

# Run tests with prove (use -b for blib/arch, required for XS modules)
perlbrew exec --with perl-5.40.0@default prove -bv t/10-basic-server.t
perlbrew exec --with perl-5.40.0@default prove -b t/*.t

# Clean build artifacts
perlbrew exec --with perl-5.40.0@default make clean
perlbrew exec --with perl-5.40.0@default make realclean  # Also removes Makefile
```

## Dependencies

**System requirement:** nghttp2 library must be installed:
- macOS: `brew install nghttp2`
- Debian: `apt-get install libnghttp2-dev`
- RHEL: `yum install libnghttp2-devel`
- Alternatively: `cpanm Alien::nghttp2`

**Perl minimum:** 5.016

## Architecture

### XS Layer (`nghttp2.xs`)
The XS code provides the C-to-Perl bridge:
- `nghttp2_perl_session` struct wraps nghttp2 session with Perl callbacks and an output buffer for `mem_send()`
- `nghttp2_perl_data_provider` manages per-stream state for streaming responses
- All nghttp2 callbacks are bridged to Perl subroutines via `call_perl_callback()`
- Memory management handles send buffers, data providers, and SV refcounting

### Perl API (`lib/Net/HTTP2/nghttp2/Session.pm`)
High-level wrapper providing:
- `new_server()` / `new_client()` - Session creation with callback hash
- `mem_recv($data)` / `mem_send()` - Buffer-based I/O (suitable for async frameworks)
- `submit_response()` - Supports static body, streaming callback, or no body
- `resume_stream()` - Resume deferred streams for async data availability

### I/O Model
Uses memory-based I/O rather than direct socket operations:
1. Feed incoming bytes via `mem_recv()`
2. Callbacks fire as frames are parsed
3. Call `mem_send()` to get bytes to write
4. Use `want_read()` / `want_write()` for poll-based integration

### Streaming Responses
Data provider callbacks receive `($stream_id, $max_length)` and return:
- `($data, $eof_flag)` - Send data, EOF=1 ends stream
- `undef` or empty list - Defer; call `resume_stream()` when data ready

## Key Files

| File | Purpose |
|------|---------|
| `nghttp2.xs` | XS bindings (~1100 lines) |
| `lib/Net/HTTP2/nghttp2.pm` | Constants and XSLoader |
| `lib/Net/HTTP2/nghttp2/Session.pm` | Session API wrapper |
| `Makefile.PL` | Build config with nghttp2 detection |

## Test Structure

Tests require nghttp2 to be installed; they skip gracefully if unavailable.

### Test Helpers
- `t/lib/Test/HTTP2/Frame.pm` - HTTP/2 frame building utilities
- `t/lib/Test/HTTP2/HPACK.pm` - Simple HPACK encoder for testing

### Unit Tests
- `t/00-load.t` - Module loading, constants
- `t/01-session.t` - Session creation, HTTP/2 preface handling
- `t/02-streaming.t` - Streaming response API

### Compliance Tests (ported from python-hyper/h2)
- `t/10-basic-server.t` - Basic server operations (11 subtests)
- `t/11-invalid-frames.t` - Protocol violation detection (13 subtests)
- `t/12-flow-control.t` - Flow control and WINDOW_UPDATE (9 subtests)
- `t/13-stream-states.t` - Stream state machine (14 subtests)
- `t/14-hpack-headers.t` - HPACK and header validation (13 subtests)
- `t/15-continuation.t` - CONTINUATION frame handling (10 subtests)
- `t/16-priority.t` - PRIORITY frame handling (11 subtests)
- `t/17-client.t` - Client-side behavior (14 subtests)

**Total: 110 tests** covering RFC 9113 compliance.
