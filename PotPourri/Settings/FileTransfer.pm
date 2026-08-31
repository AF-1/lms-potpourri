#
# PotPourri
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::PotPourri::Settings::FileTransfer;

use strict;
use warnings;
use utf8;

use base qw(Plugins::PotPourri::Settings::BaseSettings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::OSDetect;
use File::Basename qw(dirname basename);
use File::Spec::Functions qw(catfile);
use Cwd ();

use Plugins::PotPourri::Common ':all';

my $log = logger('plugin.potpourri');
my $prefs = preferences('plugin.potpourri');
my $serverPrefs = preferences('server');
my @ALLOWED_EXTENSIONS = qw(xml txt);

sub new {
	my ($class, $plugin) = @_;
	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_POTPOURRI_SETTINGS_FILETRANSFER');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/PotPourri/settings/filetransfer.html');
}

sub currentPage {
	return Slim::Utils::Strings::string('PLUGIN_POTPOURRI_SETTINGS_FILETRANSFER');
}

sub pages {
	return [{ 'name' => Slim::Utils::Strings::string('PLUGIN_POTPOURRI_SETTINGS_FILETRANSFER'), 'page' => page() }];
}

sub prefs {
	return $prefs;
}

sub handler {
	my ($class, $client, $paramRef) = @_;

	if ($paramRef->{'filetransferexecute'}) {
		my $sourceFile = $paramRef->{'filetransfersource'};
		my $targetDir = $paramRef->{'filetransfertarget'};
		my $mode = ($paramRef->{'filetransfermode'} && $paramRef->{'filetransfermode'} eq 'move') ? 'move' : 'copy';
		my $allowedDirs = [map { $_->{'path'} } @{_getAllowedDirs()}];

		if (!$sourceFile || !isPathAllowed(dirname($sourceFile), $allowedDirs)) {
			$log->warn("Rejected file transfer, source path not allowed: ".($sourceFile || ''));
			$paramRef->{'filetransfersourcepatherror'} = 1;
		} else {
			my ($extension) = $sourceFile =~ /\.([^.]+)$/;
			if (!$extension || !grep { lc($_) eq lc($extension) } @ALLOWED_EXTENSIONS) {
				$log->warn("Rejected file transfer, extension not allowed: $sourceFile");
				$paramRef->{'filetransfersourceextensionerror'} = 1;
			}
		}

		if (!$targetDir || !isPathAllowed($targetDir, $allowedDirs)) {
			$log->warn("Rejected file transfer, target path not allowed: ".($targetDir || ''));
			$paramRef->{'filetransfertargeterror'} = 1;
		} elsif (!isPathWritable($targetDir)) {
			$log->warn("Rejected file transfer, target path not writable: $targetDir");
			$paramRef->{'filetransfertargeterror'} = 1;
		}

		if (!$paramRef->{'filetransfersourcepatherror'} && !$paramRef->{'filetransfersourceextensionerror'} && !$paramRef->{'filetransfertargeterror'}) {
			my $destPath = catfile($targetDir, basename($sourceFile));
			my ($success, $error) = transferFile($sourceFile, $destPath, $mode);

			if ($success) {
				main::INFOLOG && $log->is_info && $log->info(($mode eq 'move' ? 'Moved ' : 'Copied ').$sourceFile.' to '.$destPath);
				$paramRef->{'filetransfersuccess'} = 1;
			} else {
				$log->error("File transfer failed ($sourceFile -> $destPath): $error");
				$paramRef->{'filetransfertransfererror'} = 1;
			}
		}
	}

	return $class->SUPER::handler($client, $paramRef);
}

sub beforeRender {
	my ($class, $paramRef) = @_;

	my $allowedDirs = _getAllowedDirs();
	my @permissionwarnings;

	foreach my $dir (@{$allowedDirs}) {
		next unless -d $dir->{'path'};
		push @permissionwarnings, $dir->{'label'}.' ('.$dir->{'path'}.')' unless isPathWritable($dir->{'path'});
	}

	$paramRef->{'filetransferdirs'} = $allowedDirs;
	$paramRef->{'filetransferpermissionwarnings'} = \@permissionwarnings if scalar @permissionwarnings;
	$paramRef->{'filetransferallowedextensions'} = \@ALLOWED_EXTENSIONS;
}

sub _getAllowedDirs {
	my @dirs;

	my $prefsDir = Slim::Utils::OSDetect::dirsFor('prefs');
	push @dirs, {label => Slim::Utils::Strings::string('PLUGIN_POTPOURRI_SETTINGS_FILETRANSFER_LOCATION_PREFS'), path => $prefsDir} if $prefsDir && -d $prefsDir;

	my $playlistDir = $serverPrefs->get('playlistdir');
	push @dirs, {label => Slim::Utils::Strings::string('PLUGIN_POTPOURRI_SETTINGS_FILETRANSFER_LOCATION_PLAYLISTS'), path => $playlistDir} if $playlistDir && -d $playlistDir;

	foreach my $mediaDir (@{$serverPrefs->get('mediadirs') || []}) {
		push @dirs, {label => Slim::Utils::Strings::string('PLUGIN_POTPOURRI_SETTINGS_FILETRANSFER_LOCATION_MEDIADIR_PREFIX').' '.(basename($mediaDir) || $mediaDir), path => $mediaDir} if -d $mediaDir;
	}

	push @dirs, @{_getMountedVolumes()};

	my %seen;
	return [grep { my $resolved = Cwd::realpath($_->{'path'}) || $_->{'path'}; !$seen{$resolved}++ } @dirs];
}

sub _getMountedVolumes {
	my @volumes;
	return \@volumes if main::ISWINDOWS || main::ISMAC || !-r '/proc/mounts';

	my %excludedFstypes = map { $_ => 1 } qw(tmpfs cgroup cgroup2 mqueue hugetlbfs fusectl pstore autofs binfmt_misc squashfs overlay ramfs efivarfs bpf);
	my @excludedMountpointPrefixes = qw(/proc /sys /dev /run /boot /tmp);

	open(my $fh, '<', '/proc/mounts') or return \@volumes;
	while (my $line = <$fh>) {
		my ($device, $mountpoint, $fstype) = split(/\s+/, $line);
		next unless defined $mountpoint && defined $fstype;
		next if $mountpoint eq '/';
		next if $excludedFstypes{$fstype};
		next if grep { $mountpoint eq $_ || index($mountpoint, $_.'/') == 0 } @excludedMountpointPrefixes;
		$mountpoint =~ s/\\040/ /g;
		next unless -d $mountpoint;
		push @volumes, {label => _getVolumeLabel($device, $mountpoint), path => $mountpoint};
	}
	close($fh);

	my %labelCount;
	$labelCount{$_->{'label'}}++ for @volumes;
	foreach my $volume (@volumes) {
		$volume->{'label'} .= ' ('.$volume->{'path'}.')' if $labelCount{$volume->{'label'}} > 1;
	}

	return \@volumes;
}

sub _getVolumeLabel {
	my ($device, $mountpoint) = @_;
	my $labelDir = '/dev/disk/by-label';

	if (-d $labelDir && opendir(my $dh, $labelDir)) {
		my $resolvedDevice = Cwd::realpath($device) || $device;
		while (my $entry = readdir($dh)) {
			next if $entry eq '.' || $entry eq '..';
			my $resolvedLink = Cwd::realpath(catfile($labelDir, $entry));
			if (defined $resolvedLink && $resolvedLink eq $resolvedDevice) {
				closedir($dh);
				(my $label = $entry) =~ s/\\x([0-9a-fA-F]{2})/chr(hex($1))/eg;
				return $label;
			}
		}
		closedir($dh);
	}
	return basename($mountpoint) || $mountpoint;
}

1;
