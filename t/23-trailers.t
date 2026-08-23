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
        !(grep { $_->{flags} & FLAG_END_STREAM } @data_frames),
        'final DATA does not carry END_STREAM',
    );
    is(scalar @closed, 0, 'stream remains open for a later header block');

    $server->submit_rst_stream($stream_id, NGHTTP2_CANCEL);
    pump_sessions($client, $server);
};

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

done_testing;
