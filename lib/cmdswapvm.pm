
package centreon::esxd::cmdswapvm;

use strict;
use warnings;
use centreon::esxd::common;

sub new {
    my $class = shift;
    my $self  = {};
    $self->{logger} = shift;
    $self->{obj_esxd} = shift;
    $self->{commandName} = 'swapvm';
    
    bless $self, $class;
    return $self;
}

sub getCommandName {
    my $self = shift;
    return $self->{commandName};
}

sub checkArgs {
    my $self = shift;
    my ($vm, $warn, $crit) = @_;

    if (!defined($vm) || $vm eq "") {
        $self->{logger}->writeLogError("ARGS error: need vm name");
        return 1;
    }
    if (defined($warn) && $warn !~ /^-?(?:\d+\.?|\.\d)\d*\z/) {
        $self->{logger}->writeLogError("ARGS error: warn threshold must be a positive number");
        return 1;
    }
    if (defined($crit) && $crit !~ /^-?(?:\d+\.?|\.\d)\d*\z/) {
        $self->{logger}->writeLogError("ARGS error: crit threshold must be a positive number");
        return 1;
    }
    if (defined($warn) && defined($crit) && $warn > $crit) {
        $self->{logger}->writeLogError("ARGS error: warn threshold must be lower than crit threshold");
        return 1;
    }
    return 0;
}

sub initArgs {
    my $self = shift;
    $self->{lvm} = $_[0];
    $self->{warn} = (defined($_[1]) ? $_[1] : 0.8);
    $self->{crit} = (defined($_[2]) ? $_[2] : 1);
}

sub run {
    my $self = shift;

    if (!($self->{obj_esxd}->{perfcounter_speriod} > 0)) {
        my $status = centreon::esxd::common::errors_mask(0, 'UNKNOWN');
        $self->{obj_esxd}->print_response(centreon::esxd::common::get_status($status) . "|Can't retrieve perf counters.\n");
        return ;
    }

    my %filters = ('name' => $self->{lvm});
    my @properties = ('name');
    my $result = centreon::esxd::common::get_entities_host($self->{obj_esxd}, 'VirtualMachine', \%filters, \@properties);
    if (!defined($result)) {
        return ;
    }

    my $values = centreon::esxd::common::generic_performance_values_historic($self->{obj_esxd},
                        $$result[0], 
                        [{'label' => 'mem.swapinRate.average', 'instances' => ['']},
                         {'label' => 'mem.swapoutRate.average', 'instances' => ['']}],
                        $self->{obj_esxd}->{perfcounter_speriod});

    my $swap_in = centreon::esxd::common::simplify_number(centreon::esxd::common::convert_number($values->{$self->{obj_esxd}->{perfcounter_cache}->{'mem.swapinRate.average'}->{'key'} . ":"}[0]));
    my $swap_out = centreon::esxd::common::simplify_number(centreon::esxd::common::convert_number($values->{$self->{obj_esxd}->{perfcounter_cache}->{'mem.swapoutRate.average'}->{'key'} . ":"}[0]));
    my $status = 0; # OK
    my $output = '';

    if (($swap_in / 1024) >= $self->{warn} || ($swap_out / 1024) >= $self->{warn}) {
        $status = centreon::esxd::common::errors_mask($status, 'WARNING');
    }
    if (($swap_in / 1024) >= $self->{crit} || ($swap_out / 1024) >= $self->{crit}) {
        $status = centreon::esxd::common::errors_mask($status, 'CRITICAL');
    }

    $output = "Swap In : " . centreon::esxd::common::simplify_number($swap_in / 1024 * 8) . " Mb/s , Swap Out : " . centreon::esxd::common::simplify_number($swap_out / 1024 * 8) . " Mb/s ";
    $output .= "|swap_in=" . ($swap_in * 1024 * 8) . "b/s swap_out=" . (($swap_out * 1024 * 8)) . "b/s";

    $self->{obj_esxd}->print_response(centreon::esxd::common::get_status($status) . "|$output\n");
}

1;
