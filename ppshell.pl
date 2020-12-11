#!/usr/bin/perl

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

use constant COMMAND_PREFIX => '\\';
use constant SSH_INSTANCE => 'SSH_INSTANCE';
use constant CHANNELS => 'CHANNELS';
use constant CURR_READER => 'CURR_READER';
use constant GMEMBERS => 'GMEMBERS';
use constant INITFILE => "$ENV{'HOME'}/.ppshellrc";

my %ssh_connections;
my %groups;
my $active_conn;
my $password_input_mode = 0;

sub print_prompt {
  my $prompt = '$ ';
  if (defined $active_conn) {
    $prompt = "${active_conn} ${prompt}";
  }
  print $prompt ;
}

sub handle_input {
  my ($input) = @_;
  # TODO: move chomp to where the input is received
  chomp($input);
  if ($password_input_mode) {
    system('stty', 'echo');
    $password_input_mode = 0;
  }

  if (index($input, COMMAND_PREFIX) == 0) {
    command_handler($input);
  }
  elsif (defined $active_conn and exists $ssh_connections{$active_conn}) {
    print {$ssh_connections{$active_conn}{CHANNELS}[0]} $input, "\n";
  }
  elsif (defined $active_conn and exists $groups{$active_conn}) {
    for my $connection_id (@{$groups{$active_conn}{GMEMBERS}}) {
      if (exists $ssh_connections{$connection_id}) {
        print {$ssh_connections{$connection_id}{CHANNELS}[0]} $input, "\n";
      }
    }
  }
  else {
    print "No active shell found. Select or open one.\n";
  }
}

sub command_handler {
  my ($input)  = @_;

  my @args = split / /, $input;
  my $command = substr shift @args, 1;
  for ($command) {
    when (/^h(elp)?\b/) { print_help() }
    when (/^e(xit)?\b/) { do_exit() }
    when (/^o(pen)?\b/) { open_new_shell(@args) }
    when (/^r(ead)?\b/) { output_reader() }
    when (/^lsh(ost)?\b/) { list_hosts() }
    when (/^sw(itch)?\b/) { switch_active(@args) }
    when (/^c(lose)?\b/) { close_shell(@args) }
    when (/^p(assmode)?\b/) { password_mode() }
    when (/^ag(roup)?\b/) { add_group(@args) }
    when (/^rg(roup)?\b/) { remove_group(@args) }
    when (/^lsg(roups)?\b/) { list_groups(@args) }
    when (/^s(ave)?\b/) { save_conf() }
    default { print "${command}: command not found\n" }
  }
}

sub print_help {
  my $help = "ppshell v0.1\n";
  $help .= "Commands have to be prepended by ".COMMAND_PREFIX.".\n";
  $help .= "h/help\t\tPrint this help.\n";
  $help .= "e/exit\t\tExits ppshell.\n";
  $help .= "o/open\t\tOpen ssh connection.\n";
  $help .= "r/read\t\tRead commands output.\n";
  $help .= "lsh/lshost\tList established connections.\n";
  $help .= "sw/switch\tSwitch active connection. Can use a group name.\n";
  $help .= "c/close\t\tClose connection.\n";
  $help .= "p/passmode\tHides input in ppshell.\n";
  $help .= "ag/agroup\tAdd host to a group.\n";
  $help .= "rg/rgroup\tRemove host from group.\n";
  $help .= "lsg/lsgroups\tList groups.\n";
  $help .=
    "s/save\t\tSave current connections to restore them on next launch.\n";

  print $help;
}

sub do_exit {
  close_shell('all');
  print "Bye.\n";
  exit 0;
}

sub output_reader {
  if (defined $active_conn and exists $ssh_connections{$active_conn}) {
    my $fh = $ssh_connections{$active_conn}{CHANNELS}[1];
    while (read $fh, my $buffer, 100) {
      print $buffer;
    }
  }
  elsif (defined $active_conn and exists $groups{$active_conn}) {
    for my $connection_id (@{$groups{$active_conn}{GMEMBERS}}) {
      print "Output from ${connection_id}:\n";
      my $fh = $ssh_connections{$connection_id}{CHANNELS}[1];
      while (read $fh, my $buffer, 100) {
        print $buffer;
      }
      print "\n";
    }
  }
}

sub open_new_shell {
  if (scalar @_ != 1) {
    print STDERR 
      "Error: ".COMMAND_PREFIX."open needs one target user\@server.\n";
    return;
  }
  my ($ssh_target) = @_;

  my $new_ssh_conn = Net::OpenSSH->new($ssh_target);
  if ($new_ssh_conn->error) {
    print "SSH connection failed: " . $new_ssh_conn->error;
    return;
  }
  my @connection_channels =
    $new_ssh_conn->open2({tty => 0, stderr_to_stdout => 1});
  $connection_channels[1]->blocking(0);
  $connection_channels[1]->autoflush();

  $ssh_connections{$ssh_target}{SSH_INSTANCE} = $new_ssh_conn;
  $ssh_connections{$ssh_target}{CHANNELS} = [@connection_channels];
  $active_conn = $ssh_target;
}

sub list_hosts {
  if (scalar(%ssh_connections) > 0) {
    print "Available connections:\n";
    for my $key (keys %ssh_connections) {
      print "- ${key}\n";
    }
  }
  else {
    print "No active connections found.\n";
  }
}

sub switch_active {
  if (scalar @_ != 1) {
    print STDERR "Error: ".COMMAND_PREFIX."/switch needs one connection id.\n";
    return;
  }
  my ($connection_id) = @_;

  if (exists $ssh_connections{$connection_id}) {
      $active_conn = $connection_id;
      print "Active host: ${connection_id}.\n";
  }
  elsif (exists $groups{$connection_id}) {
      $active_conn = $connection_id;
      print "Active group: ${connection_id}.\n";
  }
  else {
      print 'Host not found. ',
        "Use ".COMMAND_PREFIX."open to open a new connection.\n";
  }
}

sub close_shell {
  if (scalar @_ != 1) {
      print STDERR "Error: ".COMMAND_PREFIX."close needs at least an host.\n";
      return;
  }
  my ($connection_id) = @_;

  if ($connection_id eq "all") {
    foreach my $key (keys %ssh_connections) {
      $ssh_connections{$key}{SSH_INSTANCE}->disconnect(0);
      delete $ssh_connections{$key};
    }
    undef $active_conn;
    print "Disconnected from all shells.\n";
  }
  elsif (exists $ssh_connections{$connection_id}) {
    $ssh_connections{$connection_id}{SSH_INSTANCE}->disconnect(0);
    delete $ssh_connections{$connection_id};
    if ($active_conn and $connection_id eq $active_conn) {
      undef $active_conn;
    }
    print "Disconnected from ${connection_id}.\n";
  }
  else {
    print "Shell not found.\n";
  }
}

sub password_mode {
  system("stty", "-echo");
  $password_input_mode = 1;
}

sub add_group {
  if (scalar @_ != 2) {
      print STDERR
        "Error: ".COMMAND_PREFIX."agroup needs an host and a group.\n",
        "Usage: ".COMMAND_PREFIX."addgroup host group\n";
      return;
  }
  my ($host, $group) = @_;

  my $valid_names = '^\s*[a-zA-Z0-9\.@]+\s*$';
  if ($host =~ /$valid_names/ and $group =~ /$valid_names/) {
    if (not exists $groups{$group}) {
      $groups{$group} = {};
      $groups{$group}{GMEMBERS} = ();
    }
    push @{$groups{$group}{GMEMBERS}}, $host;
    print "${host} correctly added to group ${group}.\n";
  }
  else {
    print STDERR
      "Error: host and group can only have letters, numbers and dots.\n";
  }
}

sub remove_group {
  if (scalar @_ != 2) {
    print STDERR
      "Error: ".COMMAND_PREFIX."rgroup needs a group and a host.\n".
      "Usage: ".COMMAND_PREFIX."rgroup group host\n";
  }
  my ($group, $host) = @_;
  
  if (exists $groups{$group}) {
    if ($host eq 'all') {
      @{$groups{$group}{GMEMBERS}} = ();
    }
    else {
      @{$groups{$group}{GMEMBERS}} =
        grep {!/$host/} @{$groups{$group}{GMEMBERS}};
    }
    print "${host} removed from ${group}\n";
  }
  else {
    print "Group ${group} not found.\n";
  }
}

sub list_groups {
  print "Group\t\tConnections\n";
  my @group_keys = keys %groups;
  if (scalar @group_keys == 0) {
    print "-\t\t-\n";
  }
  else {
    for my $group (@group_keys) {
      print "${group}:\t\t@{$groups{$group}{GMEMBERS}}\n";
    }
  }
}

sub save_conf {
  open (my $fh, '>', INITFILE);
  print $fh join(',', keys %ssh_connections), "\n";
  for my $key (keys %groups) {
      print $fh "${key}:", join(',', @{$groups{$key}{GMEMBERS}}), "\n";
  }
  close($fh);
}

print "ppshell v0.1 - Type '".COMMAND_PREFIX."h' for a list of commands.\n";

if (-e INITFILE) {
  open(my $fh, '<', INITFILE);
  my $line = <$fh>;
  chomp $line;
  for my $ssh_target (split /,/, $line) {
    open_new_shell($ssh_target);
  }
  while ($line = <$fh>) {
    chomp $line;
    my ($group, $members) = split /:/, $line;
    $groups{$group} = {};
    @{$groups{$group}{GMEMBERS}} = split /,/, $members;
  }
  close($fh);
  print INITFILE." loaded.\n";
  undef $active_conn;
}

print_prompt();
while (my $input = <>) {
  handle_input($input);
  print_prompt();
}
