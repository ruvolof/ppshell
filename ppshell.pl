#! /usr/bin/perl

use strict;
use warnings;
use experimental "switch";
use threads;
use threads::shared;
use IO::Handle;
use IO::Select;

autoflush STDOUT 1;

use Data::Dumper qw(Dumper);
use Net::OpenSSH;

use constant CMD_IDF => '/';
use constant SSH_INSTANCE => 'SSH_INSTANCE';
use constant CHANNELS => 'CHANNELS';
use constant CURR_READER => 'CURR_READER';

my %ssh_connections;
my $active_conn;

sub print_prompt {
    my $p = '$ ';
    if (defined $active_conn) {
        $p = $active_conn . ' ' . $p;
    }
    print $p;
}

print_prompt();
while (my $l = <>) {
    chomp($l);
    
    if (index($l, CMD_IDF) == 0) {
        command_handler($l);
    }
    elsif (defined $active_conn) {
        print {$ssh_connections{$active_conn}{CHANNELS}[0]} $l, "\n";
    }
    else {
        print "No active shell found. Select or open one.\n";
    }
    print_prompt();
}

sub command_handler {
    my $cmd = $_[0];
    my @args = split / /, $cmd;
    
    for ($args[0]) {
        when (/^\/o(pen)?\b/) { open_new_shell(@args) }
        when (/^\/r(ead)?\b/) { output_reader() }
        when (/^\/sw(itch)?\b/) { switch_active(@args) }
        when (/^\/c(lose)?\b/) { close_shell(@args) }
    }
}

sub output_reader {
    my $fh = $ssh_connections{$active_conn}{CHANNELS}[1];
    while (read $fh, my $c, 100) {
        print $c;
    }
}

sub open_new_shell {
    if (scalar @_ < 2) {
        print STDERR "Error: /open needs at least an host.\n";
        return;
    }

    my $ep = $_[1];

    my $nssh = Net::OpenSSH->new($ep);
    $nssh->error and print "SSH connection failed: " . $nssh->error and return;
    my @connection_channels = $nssh->open2({tty => 0, stderr_to_stdout => 1});
    $connection_channels[1]->blocking(0);
    $connection_channels[1]->autoflush();
  
    $ssh_connections{$ep}{SSH_INSTANCE} = $nssh;
    $ssh_connections{$ep}{CHANNELS} = [@connection_channels];
    $active_conn = $ep;
}

sub switch_active {
    if (scalar @_ < 2) {
        print STDERR "Error: /switch needs at least a shell.\n";
        return;
    }

    my $sh = $_[1];
    if (exists($ssh_connections{$sh})) {
        $active_conn = $sh;
    }
    else {
        print "Host not found. Use /open to open a new connections.\n"
    }
}

sub close_shell {
    if (scalar @_ < 2) {
        print STDERR "Error: /open needs at least an host.\n";
        return;
    }

    my $sh = $_[1];
    if ($sh eq "all") {
        foreach my $key (keys %ssh_connections) {
            $ssh_connections{$key}{SSH_INSTANCE}->disconnect(0);
            delete $ssh_connections{$key};
        }
        undef $active_conn;
        print "Disconnected from all shells.\n";
    }
    elsif (exists $ssh_connections{$sh}) {
        $ssh_connections{$sh}{SSH_INSTANCE}->disconnect(0);
        delete $ssh_connections{$sh};
        if ($sh eq $active_conn) {
            undef $active_conn;
        }
        print "Disconnected from $sh.\n";
    }
    else {
        print "Shell not found.\n";
    }
}

