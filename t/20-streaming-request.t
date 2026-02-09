#!/usr/bin/env perl
# Tests for streaming request body callback support
# submit_request() should accept a CODE ref body that works like
# submit_response()'s data_callback — enabling bidirectional streaming
# for Extended CONNECT (WebSocket over HTTP/2, RFC 8441).

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

    # Helper: complete client/server handshake
    sub do_handshake {
        my ($client, $server) = @_;
        $client->send_connection_preface;
        $server->send_connection_preface(enable_connect_protocol => 1);
        my $cd = $client->mem_send;
        my $sd = $server->mem_send;
        $server->mem_recv($cd);
        $client->mem_recv($sd);
        for (1..3) {
            $sd = $server->mem_send; $client->mem_recv($sd) if length($sd);
            $cd = $client->mem_send; $server->mem_recv($cd) if length($cd);
        }
    }

    #==========================================================================
    # Test: Streaming body callback sends HEADERS without END_STREAM
    #==========================================================================
    subtest 'streaming body callback: HEADERS without END_STREAM' => sub {
        my @server_frames;
        my @server_data;

        my $server = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { 0 },
                on_header        => sub { 0 },
                on_frame_recv    => sub {
                    push @server_frames, {
                        type      => $_[0]{type},
                        flags     => $_[0]{flags},
                        stream_id => $_[0]{stream_id},
                    };
                    0;
                },
                on_data_chunk_recv => sub {
                    push @server_data, { stream_id => $_[0], data => $_[1] };
                    0;
                },
                on_stream_close => sub { 0 },
            },
        );

        my $client = Net::HTTP2::nghttp2::Session->new_client(
            callbacks => {
                map { $_ => sub { 0 } }
                    qw(on_begin_headers on_header on_frame_recv
                       on_data_chunk_recv on_stream_close)
            },
        );

        do_handshake($client, $server);
        @server_frames = ();

        # Submit request with streaming callback that defers immediately
        my $stream_id = $client->submit_request(
            method    => 'CONNECT',
            path      => '/ws',
            scheme    => 'https',
            authority => 'localhost',
            headers   => [[':protocol', 'websocket']],
            body      => sub {
                my ($sid, $max_len) = @_;
                return undef;  # defer — no data yet
            },
        );

        ok($stream_id > 0, "Got valid stream ID: $stream_id");

        my $cd = $client->mem_send;
        $server->mem_recv($cd) if length($cd);

        # Exchange a couple rounds
        for (1..2) {
            my $sd = $server->mem_send;
            $client->mem_recv($sd) if length($sd);
            $cd = $client->mem_send;
            $server->mem_recv($cd) if length($cd);
        }

        # Find the HEADERS frame the server received
        my @headers = grep { $_->{type} == FRAME_HEADERS } @server_frames;
        ok(@headers >= 1, 'Server received HEADERS frame');
        ok(!($headers[0]{flags} & FLAG_END_STREAM),
            'HEADERS does NOT have END_STREAM (stream stays open)');

        done_testing;
    };

    #==========================================================================
    # Test: Streaming callback sends data when resumed
    #==========================================================================
    subtest 'streaming body callback: data delivery on resume' => sub {
        my @server_data;
        my @server_frames;

        my $server = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { 0 },
                on_header        => sub { 0 },
                on_frame_recv    => sub {
                    push @server_frames, {
                        type      => $_[0]{type},
                        flags     => $_[0]{flags},
                        stream_id => $_[0]{stream_id},
                    };
                    0;
                },
                on_data_chunk_recv => sub {
                    push @server_data, { stream_id => $_[0], data => $_[1] };
                    0;
                },
                on_stream_close => sub { 0 },
            },
        );

        my $client = Net::HTTP2::nghttp2::Session->new_client(
            callbacks => {
                map { $_ => sub { 0 } }
                    qw(on_begin_headers on_header on_frame_recv
                       on_data_chunk_recv on_stream_close)
            },
        );

        do_handshake($client, $server);
        @server_frames = ();
        @server_data   = ();

        # Queue for outbound data
        my @send_queue;
        my $send_eof = 0;

        my $stream_id = $client->submit_request(
            method    => 'CONNECT',
            path      => '/ws',
            scheme    => 'https',
            authority => 'localhost',
            headers   => [[':protocol', 'websocket']],
            body      => sub {
                my ($sid, $max_len) = @_;
                if (@send_queue) {
                    my $chunk = shift @send_queue;
                    return ($chunk, $send_eof);
                }
                return undef;  # defer
            },
        );

        ok($stream_id > 0, "Got stream ID: $stream_id");

        # Flush the HEADERS frame
        my $cd = $client->mem_send;
        $server->mem_recv($cd) if length($cd);
        for (1..2) {
            my $sd = $server->mem_send;
            $client->mem_recv($sd) if length($sd);
            $cd = $client->mem_send;
            $server->mem_recv($cd) if length($cd);
        }

        # Now queue data and resume
        push @send_queue, "Hello WS";
        $client->resume_stream($stream_id);

        $cd = $client->mem_send;
        $server->mem_recv($cd) if length($cd);

        is(scalar @server_data, 1, 'Server received 1 data chunk');
        is($server_data[0]{data}, "Hello WS", 'Data content matches');

        # The DATA frame should NOT have END_STREAM (eof=0)
        my @data_frames = grep { $_->{type} == FRAME_DATA } @server_frames;
        ok(@data_frames >= 1, 'Server received DATA frame');
        ok(!($data_frames[0]{flags} & FLAG_END_STREAM),
            'DATA does NOT have END_STREAM (stream stays open)');

        # Send another chunk with EOF
        @server_data = ();
        @server_frames = ();
        push @send_queue, "Goodbye";
        $send_eof = 1;
        $client->resume_stream($stream_id);

        $cd = $client->mem_send;
        $server->mem_recv($cd) if length($cd);

        is(scalar @server_data, 1, 'Server received second data chunk');
        is($server_data[0]{data}, "Goodbye", 'Second chunk content matches');

        @data_frames = grep { $_->{type} == FRAME_DATA } @server_frames;
        ok(@data_frames >= 1, 'Server received second DATA frame');
        ok($data_frames[0]{flags} & FLAG_END_STREAM,
            'Final DATA has END_STREAM (stream closed)');

        done_testing;
    };

    #==========================================================================
    # Test: Static body still works (backward compatibility)
    #==========================================================================
    subtest 'static body still works' => sub {
        my @server_data;

        my $server = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers   => sub { 0 },
                on_header          => sub { 0 },
                on_frame_recv      => sub { 0 },
                on_data_chunk_recv => sub {
                    push @server_data, { stream_id => $_[0], data => $_[1] };
                    0;
                },
                on_stream_close => sub { 0 },
            },
        );

        my $client = Net::HTTP2::nghttp2::Session->new_client(
            callbacks => {
                map { $_ => sub { 0 } }
                    qw(on_begin_headers on_header on_frame_recv
                       on_data_chunk_recv on_stream_close)
            },
        );

        do_handshake($client, $server);

        my $stream_id = $client->submit_request(
            method    => 'POST',
            path      => '/submit',
            scheme    => 'https',
            authority => 'localhost',
            headers   => [['content-type', 'text/plain']],
            body      => "Hello World",
        );

        my $cd = $client->mem_send;
        $server->mem_recv($cd) if length($cd);
        for (1..2) {
            my $sd = $server->mem_send;
            $client->mem_recv($sd) if length($sd);
            $cd = $client->mem_send;
            $server->mem_recv($cd) if length($cd);
        }

        is(scalar @server_data, 1, 'Server received data');
        is($server_data[0]{data}, "Hello World", 'Static body delivered');

        done_testing;
    };

    #==========================================================================
    # Test: No body still sends END_STREAM on HEADERS (backward compatibility)
    #==========================================================================
    subtest 'no body sends END_STREAM on HEADERS' => sub {
        my @server_frames;

        my $server = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers   => sub { 0 },
                on_header          => sub { 0 },
                on_frame_recv      => sub {
                    push @server_frames, {
                        type      => $_[0]{type},
                        flags     => $_[0]{flags},
                        stream_id => $_[0]{stream_id},
                    };
                    0;
                },
                on_data_chunk_recv => sub { 0 },
                on_stream_close    => sub { 0 },
            },
        );

        my $client = Net::HTTP2::nghttp2::Session->new_client(
            callbacks => {
                map { $_ => sub { 0 } }
                    qw(on_begin_headers on_header on_frame_recv
                       on_data_chunk_recv on_stream_close)
            },
        );

        do_handshake($client, $server);
        @server_frames = ();

        my $stream_id = $client->submit_request(
            method    => 'GET',
            path      => '/',
            scheme    => 'https',
            authority => 'localhost',
        );

        my $cd = $client->mem_send;
        $server->mem_recv($cd) if length($cd);

        my @headers = grep { $_->{type} == FRAME_HEADERS } @server_frames;
        ok(@headers >= 1, 'Server received HEADERS frame');
        ok($headers[0]{flags} & FLAG_END_STREAM,
            'HEADERS has END_STREAM (no body)');

        done_testing;
    };
}

done_testing;
