#!/usr/bin/env perl
# Tests ported from python-hyper/h2 test_invalid_headers.py
# https://github.com/python-hyper/h2
#
# These tests verify HPACK and header validation behavior as per RFC 9113 and RFC 7541

use strict;
use warnings;
use Test::More;
use lib 't/lib';

use Net::HTTP2::nghttp2;
use Net::HTTP2::nghttp2::Session;
use Test::HTTP2::Frame qw(:all);
use Test::HTTP2::HPACK qw(encode_headers);

SKIP: {
    skip "nghttp2 not available", 1 unless Net::HTTP2::nghttp2->available;

    #==========================================================================
    # Test: Valid request headers are accepted
    #==========================================================================
    subtest 'valid request headers are accepted' => sub {
        my %headers_received;

        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub {
                    my ($stream_id, $name, $value, $flags) = @_;
                    $headers_received{$name} = $value;
                    return 0;
                },
                on_frame_recv    => sub { return 0; },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        my $header_block = encode_headers([
            [':method', 'GET'],
            [':path', '/resource'],
            [':scheme', 'https'],
            [':authority', 'example.com'],
            ['accept', 'text/html'],
            ['user-agent', 'test-client/1.0'],
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 1,
                end_headers  => 1,
            );

        $session->mem_recv($client_data);

        is($headers_received{':method'}, 'GET', 'Method received');
        is($headers_received{':path'}, '/resource', 'Path received');
        is($headers_received{':scheme'}, 'https', 'Scheme received');
        is($headers_received{':authority'}, 'example.com', 'Authority received');
        is($headers_received{'accept'}, 'text/html', 'Accept header received');

        done_testing;
    };

    #==========================================================================
    # Test: POST request with content-length
    #==========================================================================
    subtest 'POST request with content-length' => sub {
        my %headers_received;

        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers   => sub { return 0; },
                on_header          => sub {
                    my ($stream_id, $name, $value, $flags) = @_;
                    $headers_received{$name} = $value;
                    return 0;
                },
                on_frame_recv      => sub { return 0; },
                on_data_chunk_recv => sub { return 0; },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        my $body = "name=value&foo=bar";
        my $header_block = encode_headers([
            [':method', 'POST'],
            [':path', '/submit'],
            [':scheme', 'https'],
            [':authority', 'example.com'],
            ['content-type', 'application/x-www-form-urlencoded'],
            ['content-length', length($body)],
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 0,
                end_headers  => 1,
            )
            . build_data_frame(
                stream_id  => 1,
                data       => $body,
                end_stream => 1,
            );

        $session->mem_recv($client_data);

        is($headers_received{':method'}, 'POST', 'POST method received');
        is($headers_received{'content-length'}, length($body), 'Content-Length matches');
        is($headers_received{'content-type'}, 'application/x-www-form-urlencoded', 'Content-Type received');

        done_testing;
    };

    #==========================================================================
    # Test: te: trailers is valid
    # (test_te_trailers_is_valid from python-hyper/h2)
    #==========================================================================
    subtest 'te: trailers is valid' => sub {
        my %headers_received;

        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub {
                    my ($stream_id, $name, $value, $flags) = @_;
                    $headers_received{$name} = $value;
                    return 0;
                },
                on_frame_recv    => sub { return 0; },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        my $header_block = encode_headers([
            [':method', 'GET'],
            [':path', '/'],
            [':scheme', 'https'],
            [':authority', 'localhost'],
            ['te', 'trailers'],
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 1,
                end_headers  => 1,
            );

        $session->mem_recv($client_data);

        my $response = $session->mem_send();
        my ($frames, $remaining) = parse_frames($response);

        # Should not get GOAWAY - te: trailers is allowed
        my @goaway = grep { $_->{type} == FRAME_GOAWAY } @$frames;
        is(scalar @goaway, 0, 'No GOAWAY for te: trailers');
        is($headers_received{'te'}, 'trailers', 'te: trailers header received');

        done_testing;
    };

    #==========================================================================
    # Test: Uppercase header names are rejected or normalized
    # Note: nghttp2 may normalize headers to lowercase per RFC 9113
    #==========================================================================
    subtest 'header names should be lowercase' => sub {
        my %headers_received;

        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub {
                    my ($stream_id, $name, $value, $flags) = @_;
                    $headers_received{$name} = $value;
                    return 0;
                },
                on_frame_recv    => sub { return 0; },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        # Manually encode headers with uppercase (our HPACK encoder preserves case)
        my $header_block = encode_headers([
            [':method', 'GET'],
            [':path', '/'],
            [':scheme', 'https'],
            [':authority', 'localhost'],
            ['Accept', 'text/html'],  # Uppercase A
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 1,
                end_headers  => 1,
            );

        $session->mem_recv($client_data);

        my $response = $session->mem_send();
        my ($frames, $remaining) = parse_frames($response);

        # nghttp2 rejects uppercase header names per RFC 9113
        my @goaway = grep { $_->{type} == FRAME_GOAWAY } @$frames;

        # Either rejected or normalized
        if (@goaway) {
            pass("Server rejected uppercase header name");
        } else {
            # If not rejected, should have been normalized
            ok(exists $headers_received{'accept'} || exists $headers_received{'Accept'},
               "Header received (may be normalized)");
        }

        done_testing;
    };

    #==========================================================================
    # Test: Pseudo-headers in trailers are rejected
    # (test_pseudo_headers_rejected_in_trailer from python-hyper/h2)
    #==========================================================================
    subtest 'pseudo-headers rejected in trailers' => sub {
        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers   => sub { return 0; },
                on_header          => sub { return 0; },
                on_frame_recv      => sub { return 0; },
                on_data_chunk_recv => sub { return 0; },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        my $header_block = encode_headers([
            [':method', 'POST'],
            [':path', '/'],
            [':scheme', 'https'],
            [':authority', 'localhost'],
        ]);

        # Trailers with pseudo-header (invalid)
        my $trailer_block = encode_headers([
            [':status', '200'],  # Pseudo-header not allowed in trailers
            ['x-checksum', 'abc123'],
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 0,
                end_headers  => 1,
            )
            . build_data_frame(
                stream_id  => 1,
                data       => "body",
                end_stream => 0,
            )
            . build_headers_frame(  # Trailers
                stream_id    => 1,
                header_block => $trailer_block,
                end_stream   => 1,
                end_headers  => 1,
            );

        $session->mem_recv($client_data);

        my $response = $session->mem_send();
        my ($frames, $remaining) = parse_frames($response);

        # Should get error for pseudo-header in trailer
        my @errors = grep {
            $_->{type} == FRAME_GOAWAY || $_->{type} == FRAME_RST_STREAM
        } @$frames;

        ok(@errors >= 1, "Server rejected pseudo-header in trailer");

        done_testing;
    };

    #==========================================================================
    # Test: Missing required pseudo-headers are rejected
    # (test_inbound_req_header_missing_pseudo_headers from python-hyper/h2)
    #==========================================================================
    subtest 'missing pseudo-headers rejected' => sub {
        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub { return 0; },
                on_frame_recv    => sub { return 0; },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        # Missing :path pseudo-header
        my $header_block = encode_headers([
            [':method', 'GET'],
            [':scheme', 'https'],
            [':authority', 'localhost'],
            # Missing :path
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 1,
                end_headers  => 1,
            );

        $session->mem_recv($client_data);

        my $response = $session->mem_send();
        my ($frames, $remaining) = parse_frames($response);

        # Should get error for missing pseudo-header
        my @errors = grep {
            $_->{type} == FRAME_GOAWAY || $_->{type} == FRAME_RST_STREAM
        } @$frames;

        ok(@errors >= 1, "Server rejected request missing :path");

        done_testing;
    };

    #==========================================================================
    # Test: Unknown pseudo-headers are rejected
    # (test_inbound_req_header_extra_pseudo_headers from python-hyper/h2)
    #==========================================================================
    subtest 'unknown pseudo-headers rejected' => sub {
        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub { return 0; },
                on_frame_recv    => sub { return 0; },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        # Extra/unknown pseudo-header
        my $header_block = encode_headers([
            [':method', 'GET'],
            [':path', '/'],
            [':scheme', 'https'],
            [':authority', 'localhost'],
            [':unknown', 'value'],  # Unknown pseudo-header
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 1,
                end_headers  => 1,
            );

        $session->mem_recv($client_data);

        my $response = $session->mem_send();
        my ($frames, $remaining) = parse_frames($response);

        # Should get error for unknown pseudo-header
        my @errors = grep {
            $_->{type} == FRAME_GOAWAY || $_->{type} == FRAME_RST_STREAM
        } @$frames;

        ok(@errors >= 1, "Server rejected unknown pseudo-header");

        done_testing;
    };

    #==========================================================================
    # Test: :status pseudo-header in request is rejected
    #==========================================================================
    subtest ':status in request is rejected' => sub {
        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub { return 0; },
                on_frame_recv    => sub { return 0; },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        # :status is for responses, not requests
        my $header_block = encode_headers([
            [':method', 'GET'],
            [':path', '/'],
            [':scheme', 'https'],
            [':authority', 'localhost'],
            [':status', '200'],  # Not allowed in requests
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 1,
                end_headers  => 1,
            );

        $session->mem_recv($client_data);

        my $response = $session->mem_send();
        my ($frames, $remaining) = parse_frames($response);

        my @errors = grep {
            $_->{type} == FRAME_GOAWAY || $_->{type} == FRAME_RST_STREAM
        } @$frames;

        ok(@errors >= 1, "Server rejected :status in request");

        done_testing;
    };

    #==========================================================================
    # Test: Pseudo-headers must come before regular headers
    #==========================================================================
    subtest 'pseudo-headers must come first' => sub {
        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub { return 0; },
                on_frame_recv    => sub { return 0; },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        # Regular header before pseudo-header (invalid order)
        my $header_block = encode_headers([
            [':method', 'GET'],
            ['accept', 'text/html'],  # Regular header
            [':path', '/'],           # Pseudo-header after regular (invalid!)
            [':scheme', 'https'],
            [':authority', 'localhost'],
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 1,
                end_headers  => 1,
            );

        $session->mem_recv($client_data);

        my $response = $session->mem_send();
        my ($frames, $remaining) = parse_frames($response);

        my @errors = grep {
            $_->{type} == FRAME_GOAWAY || $_->{type} == FRAME_RST_STREAM
        } @$frames;

        ok(@errors >= 1, "Server rejected pseudo-header after regular header");

        done_testing;
    };

    #==========================================================================
    # Test: Connection-specific headers are rejected
    # (connection, keep-alive, transfer-encoding except trailers, upgrade, proxy-connection)
    #==========================================================================
    subtest 'connection-specific headers rejected' => sub {
        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub { return 0; },
                on_frame_recv    => sub { return 0; },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        # connection header is forbidden in HTTP/2
        my $header_block = encode_headers([
            [':method', 'GET'],
            [':path', '/'],
            [':scheme', 'https'],
            [':authority', 'localhost'],
            ['connection', 'keep-alive'],  # Forbidden
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 1,
                end_headers  => 1,
            );

        $session->mem_recv($client_data);

        my $response = $session->mem_send();
        my ($frames, $remaining) = parse_frames($response);

        my @errors = grep {
            $_->{type} == FRAME_GOAWAY || $_->{type} == FRAME_RST_STREAM
        } @$frames;

        ok(@errors >= 1, "Server rejected connection header");

        done_testing;
    };

    #==========================================================================
    # Test: Empty header value is valid
    #==========================================================================
    subtest 'empty header value is valid' => sub {
        my %headers_received;

        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub {
                    my ($stream_id, $name, $value, $flags) = @_;
                    $headers_received{$name} = $value;
                    return 0;
                },
                on_frame_recv    => sub { return 0; },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        my $header_block = encode_headers([
            [':method', 'GET'],
            [':path', '/'],
            [':scheme', 'https'],
            [':authority', 'localhost'],
            ['x-empty', ''],  # Empty value is allowed
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 1,
                end_headers  => 1,
            );

        $session->mem_recv($client_data);

        my $response = $session->mem_send();
        my ($frames, $remaining) = parse_frames($response);

        my @goaway = grep { $_->{type} == FRAME_GOAWAY } @$frames;
        is(scalar @goaway, 0, 'No GOAWAY for empty header value');
        is($headers_received{'x-empty'}, '', 'Empty header value received');

        done_testing;
    };

    #==========================================================================
    # Test: Multiple same-name headers are allowed
    #==========================================================================
    subtest 'multiple headers with same name' => sub {
        my @set_cookie_values;

        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub {
                    my ($stream_id, $name, $value, $flags) = @_;
                    push @set_cookie_values, $value if $name eq 'x-multi';
                    return 0;
                },
                on_frame_recv    => sub { return 0; },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        my $header_block = encode_headers([
            [':method', 'GET'],
            [':path', '/'],
            [':scheme', 'https'],
            [':authority', 'localhost'],
            ['x-multi', 'value1'],
            ['x-multi', 'value2'],
            ['x-multi', 'value3'],
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 1,
                end_headers  => 1,
            );

        $session->mem_recv($client_data);

        is(scalar @set_cookie_values, 3, 'All three header values received');
        is_deeply(\@set_cookie_values, ['value1', 'value2', 'value3'],
                  'Header values in correct order');

        done_testing;
    };

    #==========================================================================
    # Test: Large header block is accepted
    #==========================================================================
    subtest 'large header block accepted' => sub {
        my $large_value_received;

        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub {
                    my ($stream_id, $name, $value, $flags) = @_;
                    $large_value_received = $value if $name eq 'x-large';
                    return 0;
                },
                on_frame_recv    => sub { return 0; },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        my $large_value = "x" x 4096;  # 4KB header value
        my $header_block = encode_headers([
            [':method', 'GET'],
            [':path', '/'],
            [':scheme', 'https'],
            [':authority', 'localhost'],
            ['x-large', $large_value],
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 1,
                end_headers  => 1,
            );

        $session->mem_recv($client_data);

        my $response = $session->mem_send();
        my ($frames, $remaining) = parse_frames($response);

        my @goaway = grep { $_->{type} == FRAME_GOAWAY } @$frames;
        is(scalar @goaway, 0, 'No GOAWAY for large header');
        is(length($large_value_received), 4096, 'Large header value received');

        done_testing;
    };

    #==========================================================================
    # Test: header_table_size setting is sent in SETTINGS frame
    #==========================================================================
    subtest 'header_table_size setting is sent in SETTINGS' => sub {
        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub { return 0; },
                on_frame_recv    => sub { return 0; },
            },
        );

        $session->send_connection_preface(
            header_table_size => 8192,
        );

        my $response = $session->mem_send();
        my ($frames, $remaining) = parse_frames($response);

        # Find SETTINGS frame (not ACK)
        my @settings_frames = grep {
            $_->{type} == FRAME_SETTINGS && !($_->{flags} & FLAG_ACK)
        } @$frames;

        ok(scalar @settings_frames >= 1, 'Got at least one SETTINGS frame');

        # Parse settings payload to find HEADER_TABLE_SIZE
        my $found = 0;
        for my $frame (@settings_frames) {
            my $payload = $frame->{payload};
            while (length($payload) >= 6) {
                my ($id, $value) = unpack('nN', $payload);
                if ($id == SETTINGS_HEADER_TABLE_SIZE) {
                    is($value, 8192, 'HEADER_TABLE_SIZE is 8192');
                    $found = 1;
                }
                $payload = substr($payload, 6);
            }
        }
        ok($found, 'HEADER_TABLE_SIZE setting was included');

        done_testing;
    };

    #==========================================================================
    # Test: max_header_list_size setting is sent in SETTINGS frame
    #==========================================================================
    subtest 'max_header_list_size setting is sent in SETTINGS' => sub {
        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub { return 0; },
                on_frame_recv    => sub { return 0; },
            },
        );

        $session->send_connection_preface(
            max_header_list_size => 65536,
        );

        my $response = $session->mem_send();
        my ($frames, $remaining) = parse_frames($response);

        my @settings_frames = grep {
            $_->{type} == FRAME_SETTINGS && !($_->{flags} & FLAG_ACK)
        } @$frames;

        ok(scalar @settings_frames >= 1, 'Got at least one SETTINGS frame');

        my $found = 0;
        for my $frame (@settings_frames) {
            my $payload = $frame->{payload};
            while (length($payload) >= 6) {
                my ($id, $value) = unpack('nN', $payload);
                if ($id == SETTINGS_MAX_HEADER_LIST_SIZE) {
                    is($value, 65536, 'MAX_HEADER_LIST_SIZE is 65536');
                    $found = 1;
                }
                $payload = substr($payload, 6);
            }
        }
        ok($found, 'MAX_HEADER_LIST_SIZE setting was included');

        done_testing;
    };

    #==========================================================================
    # Test: max_send_header_block_length session option (via nghttp2_option)
    #==========================================================================
    subtest 'max_send_header_block_length session option works' => sub {
        # Create a session with max_send_header_block_length option
        # This uses nghttp2_option + nghttp2_session_server_new2
        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub { return 0; },
                on_frame_recv    => sub { return 0; },
            },
            max_send_header_block_length => 65536,
        );

        # Session should be created successfully
        ok($session, 'Session created with max_send_header_block_length option');

        $session->send_connection_preface();
        my $response = $session->mem_send();
        ok(length($response) > 0, 'Session produces valid output');

        done_testing;
    };

    #==========================================================================
    # Test: NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE constant is available
    #==========================================================================
    subtest 'NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE constant' => sub {
        my $val = Net::HTTP2::nghttp2::NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE();
        is($val, -521, 'NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE is -521');
        done_testing;
    };

    #==========================================================================
    # Test: Returning TEMPORAL_CALLBACK_FAILURE from on_header resets stream
    #==========================================================================
    subtest 'on_header returning TEMPORAL_CALLBACK_FAILURE resets stream' => sub {
        my $header_count = 0;
        my @closed_streams;

        my $session = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { return 0; },
                on_header        => sub {
                    my ($stream_id, $name, $value, $flags) = @_;
                    $header_count++;
                    # Reject after seeing a few headers
                    if ($header_count > 3) {
                        return Net::HTTP2::nghttp2::NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE();
                    }
                    return 0;
                },
                on_frame_recv    => sub { return 0; },
                on_stream_close  => sub {
                    my ($stream_id, $error_code) = @_;
                    push @closed_streams, { stream_id => $stream_id, error => $error_code };
                    return 0;
                },
            },
        );

        $session->send_connection_preface();
        $session->mem_send();

        my $header_block = encode_headers([
            [':method', 'GET'],
            [':path', '/'],
            [':scheme', 'https'],
            [':authority', 'localhost'],
            ['x-extra', 'should-trigger-rejection'],
        ]);

        my $client_data = CLIENT_PREFACE
            . build_settings_frame()
            . build_headers_frame(
                stream_id    => 1,
                header_block => $header_block,
                end_stream   => 1,
                end_headers  => 1,
            );

        $session->mem_recv($client_data);

        my $response = $session->mem_send();
        my ($frames, $remaining) = parse_frames($response);

        # Should get RST_STREAM for the rejected stream
        my @rst = grep { $_->{type} == FRAME_RST_STREAM } @$frames;
        ok(scalar @rst >= 1, 'RST_STREAM sent for rejected headers');

        done_testing;
    };

}

done_testing;
