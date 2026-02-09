#!/usr/bin/env perl
# Tests for submit_data() - push DATA frames directly on a stream

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

    # Helper: exchange frames between client and server
    sub exchange {
        my ($client, $server) = @_;
        for (1..3) {
            my $sd = $server->mem_send; $client->mem_recv($sd) if length($sd);
            my $cd = $client->mem_send; $server->mem_recv($cd) if length($cd);
        }
    }

    #==========================================================================
    # Test: submit_data with eof=1 sends DATA + END_STREAM
    #==========================================================================
    subtest 'submit_data with eof sends DATA + END_STREAM' => sub {
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

        # Submit request with streaming callback that defers (keeps stream open)
        my $stream_id = $client->submit_request(
            method    => 'CONNECT',
            path      => '/ws',
            scheme    => 'https',
            authority => 'localhost',
            headers   => [[':protocol', 'websocket']],
            body      => sub { return undef },  # always defer
        );

        my $cd = $client->mem_send;
        $server->mem_recv($cd) if length($cd);
        exchange($client, $server);
        @server_frames = ();
        @server_data   = ();

        # Now use submit_data to send data with EOF
        $client->submit_data($stream_id, "Hello!", 1);
        $cd = $client->mem_send;
        $server->mem_recv($cd) if length($cd);

        is(scalar @server_data, 1, 'Server received 1 data chunk');
        is($server_data[0]{data}, "Hello!", 'Data content matches');

        my @data_frames = grep { $_->{type} == FRAME_DATA } @server_frames;
        ok(@data_frames >= 1, 'Server received DATA frame');
        ok($data_frames[0]{flags} & FLAG_END_STREAM,
            'DATA has END_STREAM');

        done_testing;
    };

    #==========================================================================
    # Test: submit_data with eof=0 sends DATA without END_STREAM
    #==========================================================================
    subtest 'submit_data without eof keeps stream open' => sub {
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

        my $stream_id = $client->submit_request(
            method    => 'CONNECT',
            path      => '/ws',
            scheme    => 'https',
            authority => 'localhost',
            headers   => [[':protocol', 'websocket']],
            body      => sub { return undef },
        );

        my $cd = $client->mem_send;
        $server->mem_recv($cd) if length($cd);
        exchange($client, $server);
        @server_frames = ();
        @server_data   = ();

        # Send data without EOF
        $client->submit_data($stream_id, "Frame 1", 0);
        $cd = $client->mem_send;
        $server->mem_recv($cd) if length($cd);

        is(scalar @server_data, 1, 'Server received first chunk');
        is($server_data[0]{data}, "Frame 1", 'First chunk matches');

        my @data_frames = grep { $_->{type} == FRAME_DATA } @server_frames;
        ok(@data_frames >= 1, 'Server received DATA frame');
        ok(!($data_frames[0]{flags} & FLAG_END_STREAM),
            'DATA does NOT have END_STREAM');

        # Send more data, this time with EOF
        @server_frames = ();
        @server_data   = ();

        $client->submit_data($stream_id, "Frame 2", 1);
        $cd = $client->mem_send;
        $server->mem_recv($cd) if length($cd);

        is(scalar @server_data, 1, 'Server received second chunk');
        is($server_data[0]{data}, "Frame 2", 'Second chunk matches');

        @data_frames = grep { $_->{type} == FRAME_DATA } @server_frames;
        ok(@data_frames >= 1, 'Server received second DATA frame');
        ok($data_frames[0]{flags} & FLAG_END_STREAM,
            'Final DATA has END_STREAM');

        done_testing;
    };

    #==========================================================================
    # Test: submit_data works for server responses too
    #==========================================================================
    subtest 'submit_data on server response stream' => sub {
        my @client_data;
        my @client_frames;

        my $server_stream_id;

        my $server = Net::HTTP2::nghttp2::Session->new_server(
            callbacks => {
                on_begin_headers => sub { 0 },
                on_header        => sub { 0 },
                on_frame_recv    => sub {
                    my ($frame) = @_;
                    # When we get the full request, send a streaming response
                    if ($frame->{type} == FRAME_HEADERS
                        && ($frame->{flags} & FLAG_END_STREAM)) {
                        $server_stream_id = $frame->{stream_id};
                    }
                    0;
                },
                on_data_chunk_recv => sub { 0 },
                on_stream_close    => sub { 0 },
            },
        );

        my $client = Net::HTTP2::nghttp2::Session->new_client(
            callbacks => {
                on_begin_headers => sub { 0 },
                on_header        => sub { 0 },
                on_frame_recv    => sub {
                    push @client_frames, {
                        type      => $_[0]{type},
                        flags     => $_[0]{flags},
                        stream_id => $_[0]{stream_id},
                    };
                    0;
                },
                on_data_chunk_recv => sub {
                    push @client_data, { stream_id => $_[0], data => $_[1] };
                    0;
                },
                on_stream_close => sub { 0 },
            },
        );

        do_handshake($client, $server);

        # Client sends GET request
        $client->submit_request(
            method    => 'GET',
            path      => '/',
            scheme    => 'https',
            authority => 'localhost',
        );

        my $cd = $client->mem_send;
        $server->mem_recv($cd) if length($cd);
        exchange($client, $server);

        ok(defined $server_stream_id, 'Server received request');

        # Server submits response with streaming callback that defers
        $server->submit_response($server_stream_id,
            status  => 200,
            headers => [['content-type', 'text/plain']],
            body    => sub { return undef },  # defer
        );

        my $sd = $server->mem_send;
        $client->mem_recv($sd) if length($sd);
        exchange($client, $server);
        @client_data   = ();
        @client_frames = ();

        # Use submit_data to send response body
        $server->submit_data($server_stream_id, "Response body", 1);
        $sd = $server->mem_send;
        $client->mem_recv($sd) if length($sd);

        is(scalar @client_data, 1, 'Client received response data');
        is($client_data[0]{data}, "Response body", 'Response body matches');

        my @data_frames = grep { $_->{type} == FRAME_DATA } @client_frames;
        ok(@data_frames >= 1, 'Client received DATA frame');
        ok($data_frames[0]{flags} & FLAG_END_STREAM,
            'Response DATA has END_STREAM');

        done_testing;
    };
}

done_testing;
