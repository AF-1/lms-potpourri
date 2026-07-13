#
# PotPourri
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::PotPourri::Settings::BackupRestoreSettings;

use strict;
use warnings;
use utf8;

use base qw(Plugins::PotPourri::Settings::BaseSettings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.potpourri');
my $log = logger('plugin.potpourri');

sub new {
	my ($class, $plugin) = @_;
	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_POTPOURRI_SETTINGS_BACKUPRESTORESETTINGS');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/PotPourri/settings/backuprestoresettings.html');
}

sub currentPage {
	return name();
}

sub pages {
	my %page = (
		'name' => name(),
		'page' => page(),
	);
	my @pages = (\%page);
	return \@pages;
}

sub prefs {
	return $prefs;
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result;

	if (defined $paramRef->{'pref_restoreskipprefs'}) {
		my $restoreSkipPrefs = $paramRef->{'pref_restoreskipprefs'};
		$restoreSkipPrefs =~ s/^\s+|\s+$//g;
		$prefs->set('restoreskipprefs', $restoreSkipPrefs);
	}
	$paramRef->{'restoreskipprefs'} = $prefs->get('restoreskipprefs');

	if ($paramRef->{'backup'}) {
		my $selectedfolder = $paramRef->{'pref_backupoutputfolder'};
		$paramRef->{'backupoutputfolder'} = $selectedfolder;
		$paramRef->{'saveSettings'} = 1;
		main::DEBUGLOG && $log->is_debug && $log->debug('backupoutputfolder = '.Data::Dump::dump($selectedfolder));
		if (!defined($selectedfolder) || $selectedfolder eq '') {
			$paramRef->{'backupmissingoutputfolder'} = 1;
		} elsif (!-d $selectedfolder) {
			$paramRef->{'backupinvalidoutputfolder'} = 1;
		} else {
			$prefs->set('backupoutputfolder', $selectedfolder);
			unless (Plugins::PotPourri::Plugin::createBackup()) {
				$paramRef->{'backuperror'} = 1;
			}
		}
	} elsif ($paramRef->{'listrestorecontents'} || $paramRef->{'restore'}) {
		my $selectedfile = $paramRef->{'pref_restorefile'};
		$paramRef->{'saveSettings'} = 1;
		main::DEBUGLOG && $log->is_debug && $log->debug('restorefile = '.Data::Dump::dump($selectedfile));
		if (!defined($selectedfile) || $selectedfile eq '') {
			$paramRef->{'restoremissingfile'} = 1;
		} elsif ($selectedfile !~ /\.zip$/i) {
			$paramRef->{'restoremissingfile'} = 2;
			$paramRef->{'restorefilefolder'} = $selectedfile;
		} elsif (!-f $selectedfile) {
			$paramRef->{'restoremissingfile'} = 3;
			$paramRef->{'restorefilefolder'} = $selectedfile;
		} else {
			$prefs->set('restorefile', $selectedfile);
			$paramRef->{'restorefilefolder'} = $selectedfile;
			my $archiveContents = Plugins::PotPourri::Plugin::listBackupContents($selectedfile);

			if ($paramRef->{'restore'}) {
				my %selectedNamespaces;
				for (my $i = 0; $i < scalar @{$archiveContents}; $i++) {
					$selectedNamespaces{$archiveContents->[$i]->{'namespace'}} = 1 if $paramRef->{"pref_selected_$i"};
				}
				if (%selectedNamespaces) {
					my ($restoreOk, undef) = Plugins::PotPourri::Plugin::restoreFromBackup(\%selectedNamespaces);
					unless ($restoreOk) {
						$paramRef->{'restoreerror'} = 1;
						# keep showing the list on failure so the user can retry without listing again
						$paramRef->{'restorearchivecontents'} = $archiveContents;
					}
				} else {
					# nothing selected - just display the list again
					$paramRef->{'restorearchivecontents'} = $archiveContents;
				}
			} else {
				$paramRef->{'restorearchivecontents'} = $archiveContents;
			}
		}
	}

	$result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	$paramRef->{'squeezebox_server_jsondatareq'} = '/jsonrpc.js';
	$paramRef->{'activebackuprestore'} = 1 if $prefs->get('status_backuprestore');
}

1;
