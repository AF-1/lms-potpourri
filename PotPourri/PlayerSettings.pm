#
# PotPourri
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::PotPourri::PlayerSettings;

use strict;
use warnings;
use utf8;

use base qw(Slim::Web::Settings);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $serverPrefs = preferences('server');
my $prefs = preferences('plugin.potpourri');
my $log = logger('plugin.potpourri');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_POTPOURRI_STARTVOLUME');
}

sub needsClient {
	return 1;
}

sub validFor {
	return 1;
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/PotPourri/settings/player.html');
}

sub prefs {
	my $class = shift;
	my $client = shift;
	return ($prefs->client($client), qw(enabledsetstartvolumelevel allowRaise presetVolume limitvolumecontrol limitvolumecontrollevel));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	if ($paramRef->{'saveSettings'}) { }
	my $result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

1;
