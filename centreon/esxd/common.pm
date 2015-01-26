
package centreon::esxd::common;

use warnings;
use strict;
use Data::Dumper;
use VMware::VIRuntime;
use VMware::VILib;
use ZMQ::LibZMQ3;
use ZMQ::Constants qw(:all);
use centreon::plugins::options;
use centreon::plugins::output;
use centreon::plugins::perfdata;

my $manager_display = {};
my $flag = ZMQ_NOBLOCK | ZMQ_SNDMORE;

sub init_response {
    $manager_display->{options} = centreon::plugins::options->new();
    $manager_display->{output} = centreon::plugins::output->new(options => $manager_display->{options});
    $manager_display->{perfdata} = centreon::plugins::perfdata->new(output => $manager_display->{output});
    
    return $manager_display;
}

sub response {
    my (%options) = @_;

    my $stdout = '';
    if (!defined($options{stdout})) {
        local *STDOUT;
        $manager_display->{output}->{option_results}->{output_json} = 1;
        open STDOUT, '>', \$stdout;
        $manager_display->{output}->display(force_long_output => 1, nolabel => 1);
    } else {
        $stdout = $options{stdout};
    }
    
    if (defined($options{reinit})) {
         my $context = zmq_init();
         $options{endpoint} = zmq_socket($context, ZMQ_DEALER);
         zmq_connect($options{endpoint}, $options{reinit});
         # we wait 10 seconds after. If not there is a problem... so we can quit
         # dialog from vsphere response to router
         zmq_setsockopt($options{endpoint}, ZMQ_LINGER, 10000); 
    }
    if (defined($options{identity})) {
        zmq_sendmsg($options{endpoint}, $options{identity}, $flag);
    }
    zmq_sendmsg($options{endpoint}, $options{token} . " " . $stdout, ZMQ_NOBLOCK);
}

sub vmware_error {
    my ($obj_esxd, $lerror) = @_;

    $manager_display->{output}->output_add(long_msg => $lerror);
    $obj_esxd->{logger}->writeLogError("'" . $obj_esxd->{whoaim} . "' $lerror");
    if ($lerror =~ /NoPermissionFault/i) {
        $manager_display->{output}->output_add(severity => 'UNKNOWN',
                                               short_msg => 'VMWare error: not enought permissions');
    } else {
        $manager_display->{output}->output_add(severity => 'UNKNOWN',
                                               short_msg => 'VMWare error (verbose mode for more details)');
    }
    return undef;
}

sub connect_vsphere {
    my ($logger, $whoaim, $timeout_vsphere, $session1, $service_url, $username, $password) = @_;
    $logger->writeLogInfo("'$whoaim' Vsphere connection in progress");
    eval {
        $SIG{ALRM} = sub { die('TIMEOUT'); };
        alarm($timeout_vsphere);
        $$session1 = Vim->new(service_url => $service_url);
        $$session1->login(
                user_name => $username,
                password => $password);
        alarm(0);
    };
    if ($@) {
        $logger->writeLogError("'$whoaim' No response from VirtualCenter server") if($@ =~ /TIMEOUT/);
        $logger->writeLogError("'$whoaim' You need to upgrade HTTP::Message!") if($@ =~ /HTTP::Message/);
        $logger->writeLogError("'$whoaim' Login to VirtualCenter server failed: $@");
        return 1;
    }
#    eval {
#        $session_id = Vim::get_session_id();
#    };
#    if($@) {
#        writeLogFile("Can't get session_id: $@\n");
#        return 1;
#    }
    return 0;
}

sub heartbeat {
    my (%options) = @_;
    my $stime;
    
    eval {
        $stime = $options{connector}->{session1}->get_service_instance()->CurrentTime();
        $options{connector}->{keeper_session_time} = time();
    };
    if ($@) {
        $options{connector}->{logger}->writeLogError("$@");
        # Try a second time
        eval {
            $stime = $options{connector}->{session1}->get_service_instance()->CurrentTime();
            $options{connector}->{keeper_session_time} = time();
        };
        if ($@) {
            $options{connector}->{logger}->writeLogError("$@");
            $options{connector}->{logger}->writeLogError("'" . $options{connector}->{whoaim} . "' Ask a new connection");
            # Ask a new connection
            $options{connector}->{last_time_check} = time();
        }
    }
    
    $options{connector}->{logger}->writeLogInfo("'" . $options{connector}->{whoaim} . "' Get current time = " . Data::Dumper::Dumper($stime));
}

sub simplify_number {
    my ($number, $cnt) = @_;
    $cnt = 2 if (!defined($cnt));
    return sprintf("%.${cnt}f", "$number");
}

sub convert_number {
    my ($number) = shift(@_);
    # Avoid error counter empty. But should manage it in code the 'undef'.
    $number = 0 if (!defined($number));
    $number =~ s/\,/\./;
    return $number;
}

sub get_views {
    my $obj_esxd = shift;
    my $results;

    eval {
        $results = $obj_esxd->{session1}->get_views(mo_ref_array => $_[0], properties => $_[1]);
    };
    if ($@) {
        vmware_error($obj_esxd, $@);
        return undef;
    }
    return $results;
}

sub get_view {
    my $obj_esxd = shift;
    my $results;

    eval {
        $results = $obj_esxd->{session1}->get_view(mo_ref => $_[0], properties => $_[1]);
    };
    if ($@) {
        vmware_error($obj_esxd, $@);
        return undef;
    }
    return $results;
}

sub search_in_datastore {
    my $obj_esxd = shift;
    my ($ds_browse, $ds_name, $query, $return) = @_;
    my $result;
    
    my $files = FileQueryFlags->new(fileSize => 1,
                                    fileType => 1,
                                    modification => 1,
                                    fileOwner => 1
                                    );
    my $hostdb_search_spec = HostDatastoreBrowserSearchSpec->new(details => $files,
                                                                 query => $query);
    eval {
        $result = $ds_browse->SearchDatastoreSubFolders(datastorePath=> $ds_name,
                                        searchSpec=>$hostdb_search_spec);
    };
    if ($@) {
        return (undef, $@) if (defined($return) && $return == 1);
        vmware_error($obj_esxd, $@);
        return undef;
    }
    return $result;
}

sub get_perf_metric_ids {
    my $obj_esxd = shift;
    my $perf_names = $_[0];
    my $filtered_list = [];
   
    foreach (@$perf_names) {
        if (defined($obj_esxd->{perfcounter_cache}->{$_->{label}})) {
            foreach my $instance (@{$_->{instances}}) {
                my $metric = PerfMetricId->new(counterId => $obj_esxd->{perfcounter_cache}->{$_->{label}}{key},
                                   instance => $instance);
                push @$filtered_list, $metric;
            }
        } else {
            $obj_esxd->{logger}->writeLogError("Metric '" . $_->{label} . "' unavailable.");
            $manager_display->{output}->output_add(severity => 'UNKNOWN',
                                                   short_msg => "Counter doesn't exist. VMware version can be too old.");
            return undef;
        }
    }
    return $filtered_list;
}

sub performance_builder_specific {
    my (%options) = @_;
    
    my @perf_query_spec;
    foreach my $entry (@{$options{metrics}}) {
        my $perf_metric_ids = get_perf_metric_ids($options{connector}, $entry->{metrics});
        return undef if (!defined($perf_metric_ids));
        
        my $tstamp = time();
        my (@t) = gmtime($tstamp - $options{interval});
        my $startTime = sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ",
            (1900+$t[5]),(1+$t[4]),$t[3],$t[2],$t[1],$t[0]);
        (@t) = gmtime($tstamp);
        my $endTime = sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ",
            (1900+$t[5]),(1+$t[4]),$t[3],$t[2],$t[1],$t[0]);
        if ($options{interval} == 20) {
            push @perf_query_spec, PerfQuerySpec->new(entity => $entry->{entity},
                                    metricId => $perf_metric_ids,
                                    format => 'normal',
                                    intervalId => 20,
                                    startTime => $startTime,
                                    endTime => $endTime,
                                    maxSample => 1);
        } else {
            push @perf_query_spec, PerfQuerySpec->new(entity => $entry->{entity},
                                    metricId => $perf_metric_ids,
                                    format => 'normal',
                                    intervalId => $options{interval},
                                    startTime => $startTime,
                                    endTime => $endTime
                                    );
                                    #maxSample => 1);
        }
    }
    
    return $options{connector}->{perfmanager_view}->QueryPerf(querySpec => \@perf_query_spec);
}

sub performance_builder_global {
    my (%options) = @_;
    
    my @perf_query_spec;
    my $perf_metric_ids = get_perf_metric_ids($options{connector}, $options{metrics});
    return undef if (!defined($perf_metric_ids));
    
    my $tstamp = time();
    my (@t) = gmtime($tstamp - $options{interval});
    my $startTime = sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ",
            (1900+$t[5]),(1+$t[4]),$t[3],$t[2],$t[1],$t[0]);
    (@t) = gmtime($tstamp);
    my $endTime = sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ",
            (1900+$t[5]),(1+$t[4]),$t[3],$t[2],$t[1],$t[0]);
        
    foreach (@{$options{views}}) {
        if ($options{interval} == 20) {
            push @perf_query_spec, PerfQuerySpec->new(entity => $_,
                                    metricId => $perf_metric_ids,
                                    format => 'normal',
                                    intervalId => 20,
                                    startTime => $startTime,
                                    endTime => $endTime,
                                    maxSample => 1);
        } else {
            push @perf_query_spec, PerfQuerySpec->new(entity => $_,
                                    metricId => $perf_metric_ids,
                                    format => 'normal',
                                    intervalId => $options{interval},
                                    startTime => $startTime,
                                    endTime => $endTime
                                    );
                                    #maxSample => 1);
        }
    }
    
    return $options{connector}->{perfmanager_view}->QueryPerf(querySpec => \@perf_query_spec);
}

sub generic_performance_values_historic {
    my ($obj_esxd, $views, $perfs, $interval, %options) = @_;
    my $counter = 0;
    my %results;
    
    eval {
        my $perfdata;
        
        if (defined($views)) {
            $perfdata = performance_builder_global(connector => $obj_esxd,
                                                   views => $views,
                                                   metrics => $perfs,
                                                   interval => $interval);
        } else {
            $perfdata = performance_builder_specific(connector => $obj_esxd,
                                                     metrics => $perfs,
                                                     interval => $interval);
        }
        return undef if (!defined($perfdata));

        if (!$$perfdata[0] || !defined($$perfdata[0]->value)) {
            $manager_display->{output}->output_add(severity => 'UNKNOWN',
                                                   short_msg => 'Cannot get value for counters (Maybe, object(s) cannot be reached: disconnected, not running,...)');
            return undef;
        }
        foreach my $val (@$perfdata) {
            foreach (@{$val->{value}}) {
                if (defined($options{skip_undef_counter}) && $options{skip_undef_counter} == 1 && !defined($_->value)) {
                    $results{$_->id->counterId . ":" . (defined($_->id->instance) ? $_->id->instance : "")} = undef;
                    next;
                } elsif (!defined($_->value)) {
                    $manager_display->{output}->output_add(severity => 'UNKNOWN',
                                                           short_msg => 'Cannot get value for counters. Maybe there is time sync problem (check the esxd server and the target also)');
                    return undef;
                }
                
                if (defined($options{multiples}) && $options{multiples} == 1) {
                    if (defined($options{multiples_result_by_entity}) && $options{multiples_result_by_entity} == 1) {
                        $results{$val->{entity}->{value}} = {} if (!defined($results{$val->{entity}->{value}}));
                        $results{$val->{entity}->{value}}->{$_->id->counterId . ":" . (defined($_->id->instance) ? $_->id->instance : "")} = $_->value;
                    } else {
                        $results{$val->{entity}->{value} . ":" . $_->id->counterId . ":" . (defined($_->id->instance) ? $_->id->instance : "")} = $_->value;
                    }
                } else {
                    $results{$_->id->counterId . ":" . (defined($_->id->instance) ? $_->id->instance : "")} = $_->value;
                }
            }
        }
    };
    if ($@) {
        $obj_esxd->{logger}->writeLogError("'" . $obj_esxd->{whoaim} . "' $@");
        return undef;
    }
    return \%results;
}

sub cache_perf_counters {
    my $obj_esxd = shift;

    eval {
        $obj_esxd->{perfmanager_view} = $obj_esxd->{session1}->get_view(mo_ref => $obj_esxd->{session1}->get_service_content()->perfManager, properties => ['perfCounter', 'historicalInterval']);
        foreach (@{$obj_esxd->{perfmanager_view}->perfCounter}) {
            my $label = $_->groupInfo->key . "." . $_->nameInfo->key . "." . $_->rollupType->val;
            $obj_esxd->{perfcounter_cache}->{$label} = {'key' => $_->key, 'unitkey' => $_->unitInfo->key};
            $obj_esxd->{perfcounter_cache_reverse}->{$_->key} = $label;
        }

        my $historical_intervals = $obj_esxd->{perfmanager_view}->historicalInterval;

        foreach (@$historical_intervals) {
            if ($obj_esxd->{perfcounter_speriod} == -1 || $obj_esxd->{perfcounter_speriod} > $_->samplingPeriod) {
                $obj_esxd->{perfcounter_speriod} = $_->samplingPeriod;
            }
        }

        # Put refresh = 20 (for ESX check)
        if ($obj_esxd->{perfcounter_speriod} == -1) {
            $obj_esxd->{perfcounter_speriod} = 20;
        }
    };
    if ($@) {
        $obj_esxd->{logger}->writeLogError("'" . $obj_esxd->{whoaim} . "' $@");
        return 1;
    }
    return 0;
}

sub get_entities_host {
    my ($obj_esxd, $view_type, $filters, $properties) = @_;
    my $entity_views;

    eval {
        $entity_views = $obj_esxd->{session1}->find_entity_views(view_type => $view_type, properties => $properties, filter => $filters);
    };
    if ($@) {
        $obj_esxd->{logger}->writeLogError("'" . $obj_esxd->{whoaim} . "' $@");
        eval {
            $entity_views = $obj_esxd->{session1}->find_entity_views(view_type => $view_type, properties => $properties, filter => $filters);
        };
        if ($@) {
            vmware_error($obj_esxd, $@);
            return undef;
        }
    }
    if (!@$entity_views) {
        my $status = 0;
        $manager_display->{output}->output_add(severity => 'UNKNOWN',
                                               short_msg => "Object $view_type does not exist");
        return undef;
    }
    #eval {
    #    $$entity_views[0]->update_view_data(properties => $properties);
    #};
    #if ($@) {
    #    writeLogFile("$@");
    #    my $lerror = $@;
    #    $lerror =~ s/\n/ /g;
    #    print "-1|Error: " . $lerror . "\n";
    #    return undef;
    #}
    return $entity_views;
}

sub performance_errors {
    my ($obj_esxd, $values) = @_;

    # Error counter not available or other from function
    return 1 if (!defined($values) || scalar(keys(%$values)) <= 0);
    return 0;
}

sub is_accessible {
    my (%options) = @_;
     
    if ($options{accessible} !~ /^true|1$/) {
        return 0;
    }
    return 1;
}

sub is_connected {
    my (%options) = @_;
     
    if ($options{state} !~ /^connected$/i) {
        return 0;
    }
    return 1;
}

sub is_running {
    my (%options) = @_;
    
    if ($options{power} !~ /^poweredOn$/i) {
        return 0;
    }
    return 1;
}

sub datastore_state {
    my (%options) = @_;
    my $status = defined($options{status}) ? $options{status} : $options{connector}->{centreonesxd_config}->{datastore_state_error};
    
    if ($options{state} !~ /^true|1$/) {
        my $output = "Datastore '" . $options{name} . "' not accessible. Current connection state: '$options{state}'.";
        if ($options{multiple} == 0 || 
            !$manager_display->{output}->is_status(value => $status, compare => 'ok', litteral => 1)) {
            $manager_display->{output}->output_add(severity => $status,
                                                   short_msg => $output);
        }
        return 0;
    }
    
    return 1;
}

sub vm_state {
    my (%options) = @_;
    my $status = defined($options{status}) ? $options{status} : $options{connector}->{centreonesxd_config}->{host_state_error};
    my $power_status = defined($options{powerstatus}) ? $options{powerstatus} : $options{connector}->{centreonesxd_config}->{vm_state_error};
    
    if ($options{state} !~ /^connected$/i) {
        my $output = "VM '" . $options{hostname} . "' not connected. Current Connection State: '$options{state}'.";
        if ($options{multiple} == 0 || 
            !$manager_display->{output}->is_status(value => $status, compare => 'ok', litteral => 1)) {
            $manager_display->{output}->output_add(severity => $status,
                                                   short_msg => $output);
        }
        return 0;
    }
    
    if (!defined($options{nocheck_ps}) && $options{power} !~ /^poweredOn$/i) {
        my $output = "VM '" . $options{hostname} . "' not running. Current Power State: '$options{power}'.";
        if ($options{multiple} == 0 || 
            !$manager_display->{output}->is_status(value => $power_status, compare => 'ok', litteral => 1)) {
            $manager_display->{output}->output_add(severity => $power_status,
                                                   short_msg => $output);
        }
        return 0;
    }
    
    return 1;
}

sub host_state {
    my (%options) = @_;
    my $status = defined($options{status}) ? $options{status} : $options{connector}->{centreonesxd_config}->{host_state_error};
    
    if ($options{state} !~ /^connected$/i) {
        my $output = "Host '" . $options{hostname} . "' not connected. Current Connection State: '$options{state}'.";
        if ($options{multiple} == 0 || 
            !$manager_display->{output}->is_status(value => $status, compare => 'ok', litteral => 1)) {
            $manager_display->{output}->output_add(severity => $status,
                                                   short_msg => $output);
        }
        return 0;
    }
    
    return 1;
}

sub strip_cr {
    my (%options) = @_;
    
    $options{value} =~ s/^\s+.*\s+$//mg;
    $options{value} =~ s/\r//mg;
    $options{value} =~ s/\n/ -- /mg;
    return $options{value};
}

sub stats_info {
    my (%options) = @_;

    my $total = 0;
    foreach my $container (keys %{$options{counters}}) {
        $total += $options{counters}->{$container};
        $options{manager}->{output}->perfdata_add(label => 'c[requests_' . $container . ']',
                                                  value => $options{counters}->{$container},
                                                  min => 0);
    }
    $options{manager}->{output}->perfdata_add(label => 'c[requests]',
                                              value => $total,
                                              min => 0);  
    $options{manager}->{output}->output_add(severity => 'OK',
                                            short_msg => sprintf("'%s' total requests", $total));
}

1;
