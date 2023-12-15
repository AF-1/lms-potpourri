#
# PotPourri
#
# (c) 2022 AF-1
#
# GPLv3 license
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#

package Plugins::PotPourri::Importer;

use strict;
use warnings;
use utf8;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Schema;
use Plugins::PotPourri::Common ':all';

my $prefs = preferences('plugin.potpourri');
my $serverPrefs = preferences('server');
my $log = Slim::Utils::Log::logger('plugin.potpourri');

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
