use 5.014;

package Mojo::UserAgent::Mockable::Serializer;

use warnings::register;

use Carp;
use Class::Load ':all';
use Data::Serializer::Raw;
use English qw/-no_match_vars/;
use File::Slurp qw/slurp write_file/;
use JSON::MaybeXS qw/encode_json decode_json/;
use Mojo::Base 'Mojo::EventEmitter';
use Safe::Isa (qw/$_isa/);
use TryCatch;

# ABSTRACT: A class that serializes Mojo transactions created by Mojo::UserAgent::Mockable.

# VERSION

=head1 SYNOPSIS

    # This module is not intended to be used directly. Synopsis here is given to show how 
    # Mojo::UserAgent::Mockable uses the module to record transactions.
    
    use Mojo::UserAgent::Mockable::Serializer;
    use Mojo::UserAgent;

    my $ua = Mojo::UserAgent->new;
    my $serializer = Mojo::UserAgent::Mockable::Serializer->new;
    
    my @transactions;
    push @transactions, $ua->get('http://example.com');
    push @transactions, $ua->get('http://example.com/object/123');
    push @transactions, $ua->get('http://example.com/subobject/456');

    my $json = $serializer->serialize(@transactions);
    write_file('/path/to/file.json', $json);

    # OR

    $serializer->store('/path/to/file.json', @transactions);

    # Later...

    my $json = read_file('/path/to/file.json');
    my @reconstituted_transactions = $serializer->deserialize($json);

    # OR
    #
    my @reconstituted_transactions = Mojo::UserAgent::Mockable::Serializer->retrieve('/path/to/file.json');

=head1 EVENTS

This module emits the following events:

=head2 pre_thaw

    $serializer->on( pre_thaw => sub {
        my ($serializer, $slush) = @_;
        ...
    });

Emitted immediately before transactions are deserialized. See L</DATA STRUCTURE> below for details
of the format of $slush.

=head2 post_thaw

    # Note that $transactions is an arrayref here.
    $serializer->on( post_thaw => sub {
        my ($serializer, $transactions, $slush) = @_;
        ...
    }

Emitted immediately after transactions are deserialized. See L</DATA STRUCTURE> below for details
of the format of $slush.

In addition, each transaction, as well as each message therein, serialized using this module will 
emit the following events:

=head2 pre_freeze
    
    $transaction->on(freeze => sub {
        my $tx = shift;
        ...
    });

Emitted immediately before the transaction is serialized.

=head2 post_freeze

Emitted immediately after the transaction is serialized. See L</Messages> for details of the 
frozen format. 

    $transaction->on(post_freeze => sub {
        my $tx = shift;
        my $frozen = shift;
        ...
    });

=head1 DATA STRUCTURE

L<serialize> produces, and L<deserialize> expects, JSON data. Transactions are stored as an array 
of JSON objects (i.e. hashes). Each transaction object has the keys:

=for :list
= 'class'
The original class of the transaction.
= 'request'
The request portion of the transaction (e.g. "GET /foo/bar ..."). See L</Messages> below for 
encoding details.
= 'response'
The response portion of the transaction (e.g. "200 OK ..."). See L</Messages> below for encoding
details.

=head2 Messages

Individual messages are stored as JSON objects (i.e. hashes) with the keys:

=for :list
= 'class'
The class name of the serialized object.  This should be a subclass of L<Mojo::Message>
= 'events'
Array of events with subscribers in the serialized object. These events will be re-emitted after 
the L</thaw> event is emitted, but any subscribers present in the original object will be lost.
= 'body'
The raw HTTP message body.

=head1 CAVEATS

This module does not serialize any event listeners.  This is unlikely to change in future releases.

=method serialize

Serialize or freeze one or more instances of L<Mojo::Transaction>.  Takes an array of transactions 
to be serialized as the single argument. This method will generate a warning if the instance has 
any subscribers (see L<Mojo::EventEmitter/on>).  Suppress this warning with (e.g.):

  no warnings 'Mojo::UserAgent::Mock::Serializer';
  $serializer->serialize(@transactions);
  use warnings 'Mojo::UserAgent::Mock::Serializer';

=method deserialize

Deserialize or thaw a previously serialized array of L<Mojo:Transaction>. Arguments:

=for :list
= $data 
JSON containing the serialized objects.

=method store

Serialize an instance of L<Mojo::Transaction> and write it to the given file or file handle.  Takes two
arguments:

=for :list
= $file 
File or handle to write serialized object to.
= @transactions
Array of L<Mojo::Transaction> to serialize
 
=method retrieve

Read from the specified file or file handle and deserialize one or more instances of 
L<Mojo::Transaction> from the data read.  If a file handle is passed, data will be 
read until an EOF is received. Arguments:

=for :list
= $file
File containing serialized object

=cut

sub serialize {
    my ($self, @transactions) = @_;

    my @serialized = map { $self->_serialize_tx($_) } @transactions;
    return encode_json(\@serialized);
}

sub _serialize_tx {
    my ($self, $transaction) = @_;

    if (!$transaction->$_isa('Mojo::Transaction')) {
        croak q{Only instances of Mojo::Transaction may be serialized using this class};
    }

    $transaction->emit('pre_freeze');
    my $slush = {
        request => $self->_serialize_message($transaction->req),
        response => $self->_serialize_message($transaction->res),
        class => ref $transaction,
    };
    for my $event (keys %{$transaction->{'events'}}) {
        next if $event eq 'pre_freeze' or $event eq 'post_freeze';
        carp(qq{Subscriber for event "$event" not serialized}) if warnings::enabled; 
        push @{$slush->{'events'}}, $event;
    }

    $transaction->emit('post_freeze', $slush);

    return $slush;
}

sub _serialize_message {
    my ( $self, $message ) = @_;

    $message->emit('pre_freeze');
    my $slush = {
        class => ref $message,
        body  => $message->to_string,
    };
    if ($message->can('url')) {
        $slush->{'url'} = $message->url->to_string;
    }
    for my $event ( keys %{ $message->{'events'} } ) {
        next if $event eq 'pre_freeze' or $event eq 'post_freeze';
        carp(qq{Subscriber for event "$event" not serialized}) if warnings::enabled;
        push @{ $slush->{'events'} }, $event;
    }

    $message->emit('post_freeze', $slush);
    return $slush;
}

sub deserialize { 
    my ($self, $frozen) = @_;

    my $slush = decode_json($frozen);

    if (ref $slush ne 'ARRAY') {
        croak q{Invalid serialized data: not stored as array.};
    }
    $self->emit('pre_thaw', $slush);

    my @transactions;
    for (0 .. $#{$slush}) {
        my $tx;
        try {
            $tx = $self->_deserialize_tx($slush->[$_]);
        }
        catch {
            my $tx_num = $_ + 1;
            croak qq{Error deserializing transaction $tx_num: $EVAL_ERROR};
        }

        push @transactions, $tx;
    }

    $self->emit('post_thaw', \@transactions, $slush);
    return @transactions;
}

sub _deserialize_tx {
    my ($self, $slush) = @_;

    for my $key (qw/class request response/) {
        if (!defined $slush->{$key}) {
            croak qq{Invalid serialized data: Missing required key '$key'};
        }
    }

    load_class($slush->{'class'});
    my $obj = $slush->{'class'}->new();

    if (!$obj->$_isa('Mojo::Transaction')) {
        croak q{Only instances of Mojo::Transaction may be deserialized using this class};
    }

    try {
        $obj->res($self->_deserialize_message($slush->{'response'}));
    }
    catch { 
        die qq{Error deserializing response: $EVAL_ERROR\n};
    }

    try {
        $obj->req($self->_deserialize_message($slush->{'request'}));
    }
    catch {
        die qq{Error deserializing request: $EVAL_ERROR\n};
    }

    if ($slush->{'events'}) {
        for my $event (@{$slush->{'events'}}) {
            $obj->emit($event);
        }
    }
    return $obj;
}

sub _deserialize_message {
    my ($self, $slush) = @_;
    for my $key (qw/body class/) {
        if (!$slush->{$key}) {
            croak qq{Invalid serialized data: missing required key "$key"};
        }
    }

    load_class($slush->{'class'});
    my $obj = $slush->{'class'}->new;
    if ($slush->{'url'} && $obj->can('url')) {
        $obj->url(Mojo::URL->new($slush->{'url'}));
    }
    if (!$obj->can('parse')) {
        die qq{Messages must define the 'parse' method\n};
    }
    $obj->parse($slush->{'body'});

    if (!$obj->can('emit')) {
        die qq{Messages must define the 'emit' method\n};
    }
    if ($slush->{'events'}) {
        for my $event (@{$slush->{'events'}}) {
            $obj->emit($event);
        }
    }

    return $obj;
}

sub store {
    my ($self, $file, @transactions) = @_;

    my $serialized = $self->serialize(@transactions);
    write_file($file, $serialized);
}

sub retrieve {
    my ($self, $file) = @_;

    my $contents = slurp($file);
    return $self->deserialize($contents);
}
1;
