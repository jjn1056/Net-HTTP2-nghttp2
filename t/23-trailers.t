use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Net::HTTP2::nghttp2 qw(
    NGHTTP2_CANCEL NGHTTP2_NO_ERROR
    NGHTTP2_HCAT_RESPONSE NGHTTP2_HCAT_HEADERS
);
use Net::HTTP2::nghttp2::Session;
use Test::HTTP2::Frame qw(
    FRAME_DATA FRAME_GOAWAY FRAME_HEADERS FRAME_RST_STREAM FLAG_END_STREAM
);

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

subtest 'callback exceptions warn, fail the send, and clean up safely' => sub {
    my ($client, $server, $client_stream_id, $stream_id) = new_pair();
    my $callback_calls = 0;

    $server->submit_response(
        $stream_id,
        status => 200,
        body   => sub {
            $callback_calls++;
            die "intentional data callback failure\n";
        },
    );

    my @warnings;
    my $sent = eval {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $server->mem_send;
        1;
    };
    my $send_error = $@;

    ok(!$sent, 'callback exception fails the outbound send');
    like(
        $send_error,
        qr/\Anghttp2_session_send failed: .*callback.*failed/i,
        'send failure reports the native callback failure',
    );
    is($callback_calls, 1, 'the failing callback is invoked once');
    is(scalar @warnings, 1, 'the callback exception produces one captured warning');
    like(
        $warnings[0],
        qr/\Anghttp2 data provider callback error: intentional data callback failure\n\z/,
        'the captured warning preserves the callback exception',
    );

    my $destroyed = eval {
        undef $server;
        undef $client;
        1;
    };
    ok($destroyed, 'sessions clean up after the callback failure');
};

subtest 'surplus callback values are discarded after the first three' => sub {
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

    my $callback_calls = 0;
    $server->submit_response(
        $stream_id,
        status => 200,
        body   => sub {
            return ('unexpected follow-up', 1) if $callback_calls++;
            return ('first-three body', 1, 1, 'surplus body', 0, 0);
        },
    );
    pump_sessions($client, $server);
    $server->submit_trailer(
        $stream_id,
        headers => [['x-surplus', 'discarded']],
    );
    pump_sessions($client, $server);

    is($callback_calls, 1, 'the second return value finishes the provider');
    is($body, 'first-three body', 'only the first return value reaches the peer');
    ok(
        !(grep { $_->{flags} & FLAG_END_STREAM } @data_frames),
        'the third return value reserves END_STREAM for trailers',
    );
    is($blocks[-1]{category}, NGHTTP2_HCAT_HEADERS, 'trailing HEADERS follows DATA');
    is_deeply(
        $blocks[-1]{headers},
        [['x-surplus', 'discarded']],
        'the trailer arrives after surplus values are discarded',
    );
    ok($blocks[-1]{flags} & FLAG_END_STREAM, 'trailing HEADERS ends the stream');
    is_deeply(
        \@closed,
        [[$client_stream_id, NGHTTP2_NO_ERROR]],
        'the stream closes normally',
    );
};

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
        status => 200,
        body   => sub { return undef },
    );
    pump_sessions($client, $server);

    my $payload = 'x' x 32768;
    $server->submit_data($stream_id, $payload, 1, 1);
    pump_sessions($client, $server);

    is($body, $payload, 'all direct data is delivered across partial reads');
    ok(@data_frames > 1, 'payload spans more than one DATA frame');
    ok(
        !(grep { $_->{flags} & FLAG_END_STREAM } @data_frames),
        'fourth argument suppresses END_STREAM at actual EOF',
    );
    is(scalar @closed, 0, 'stream remains open');

    $server->submit_rst_stream($stream_id, NGHTTP2_CANCEL);
    pump_sessions($client, $server);
};

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
        !(grep { $_->{flags} & FLAG_END_STREAM } @data_frames),
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
        !grep({ $_->{flags} & FLAG_END_STREAM } @data_frames),
        'DATA reserves END_STREAM for trailers',
    );
    ok($blocks[-1]{flags} & FLAG_END_STREAM, 'trailing HEADERS ends the stream');
    is_deeply(\@events, ['data', 'trailers'], 'body is observed before trailers');
    is_deeply(\@closed, [[$client_stream_id, NGHTTP2_NO_ERROR]], 'stream closes cleanly');
    is(scalar @terminal_frames, 0, 'no RST_STREAM or GOAWAY was needed');
};

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
        !grep({ $_->{flags} & FLAG_END_STREAM } @data_frames),
        'direct final DATA does not end the stream',
    );
    is($blocks[-1]{category}, NGHTTP2_HCAT_HEADERS, 'direct trailer is later HEADERS');
    is_deeply($blocks[-1]{headers}, [['x-direct', 'yes']], 'direct trailer arrives');
    ok($blocks[-1]{flags} & FLAG_END_STREAM, 'direct trailing HEADERS ends the stream');
    is_deeply(\@closed, [[$client_stream_id, NGHTTP2_NO_ERROR]], 'direct stream closes cleanly');
};

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

subtest 'stream ID zero fails immediately' => sub {
    my ($client, $server, $client_stream_id, $stream_id) = new_pair();
    my $ok = eval {
        $server->submit_trailer(0);
        1;
    };

    ok(!$ok, 'invalid stream ID dies');
    like($@, qr/nghttp2_submit_trailer failed:/, 'native error is reported');
};

done_testing;
