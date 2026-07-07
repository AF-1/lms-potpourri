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

my $prefs = preferences('plugin.potpourri');

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
	my ($class, $client) = @_;
	return ($prefs->client($client), qw(enabledsetstartvolumelevel allowRaise presetVolume limitvolumecontrol limitvolumecontrollevel));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	return $class->SUPER::handler($client, $paramRef);
}

1;
