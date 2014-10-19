############################################################
#
#   $Id$
#   Varz - Simple interface to monitoring metric key value pairs
#
#   Copyright 2013 Nicola Worthington
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
############################################################

package Varz;
# vim:ts=8:sw=8:tw=78

use 5.16.2;
use strict;
use warnings;

use Carp qw(croak cluck confess carp);
#use POSIX qw(strftime);
use Storable qw(dclone);

our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS, $AUTOLOAD);
BEGIN {
	require Exporter;
	@ISA = qw(Exporter);
	@EXPORT = qw();
	@EXPORT_OK = qw(varz_to_hashref define_varz inc_varz);
	%EXPORT_TAGS = (default => \@EXPORT, all => \@EXPORT_OK);
}

use version; our $VERSION = version->declare('v0.0.1');

my $varz = {};

sub AUTOLOAD {
	my $name = $AUTOLOAD;
	$name =~ s/.*:://;
	croak "Varz named '$name' does not exist"
		if !exists $varz->{$name};
	return wantarray ? (dclone($varz->{$name})) : $varz->{$name}->[0];
}

sub inc { &inc_varz; }
sub inc_varz {
	my ($class, $name) = @_;
	croak 'Name is a mandatory argument'
		if !defined $name;
	croak "Varz named '$name' does not exist"
		if !exists $varz->{$name};
	$varz->{$name}->[1]++;
	return $varz->{$name}->[1];
}

sub define { &define_varz; }
sub define_varz {
	my ($class, $name, $description, $initial_value) = @_;
	croak 'Name and description are mandatory arguments'
		if !defined $name or !defined $description;
	croak "Varz named '$name' already exists"
		if exists $varz->{$name};
	$varz->{$name} = [( $description, $initial_value )];
}

sub varz_to_hashref {
	return dclone($varz);
}

1;

