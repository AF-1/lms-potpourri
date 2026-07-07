#
# PotPourri
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::PotPourri::Importer;

use strict;
use warnings;
use utf8;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Plugins::PotPourri::Common ':all';

my $prefs = preferences('plugin.potpourri');
my $log = logger('plugin.potpourri');

sub initPlugin {
	main::DEBUGLOG && $log->is_debug && $log->debug('Importer module init');
	toggleUseImporter();
}

sub toggleUseImporter {
	if ($prefs->get('postscan_rltypes')) {
		main::DEBUGLOG && $log->is_debug && $log->debug('enabling importer');
		Slim::Music::Import->addImporter('Plugins::PotPourri::Importer', {
			'type' => 'post',
			'weight' => 499,
			'use' => 1,
		});
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug('disabling importer');
		Slim::Music::Import->useImporter('Plugins::PotPourri::Importer', 0);
	}
}

sub startScan {
	my $class = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug('Starting post-scan process to assign release types');
	$class->assignReleaseTypes();
	Slim::Music::Import->endImporter($class);
}

1;
