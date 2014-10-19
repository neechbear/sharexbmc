#!/usr/bin/env perl -w

use 5.16.2;
use strict;
use warnings;
use autodie qw(:io :threads);

use FindBin qw($RealBin $Script);
use File::Spec::Functions qw(catfile catdir);
use lib ('lib', catdir($RealBin, 'lib'));

use Dancer qw(:syntax :script);
use Dancer::Plugin::Database qw(database);
use Dancer::Serializer::Mutable qw(template_or_serialize);
use File::Basename qw(fileparse);
use Getopt::Long qw();
use Image::Magick qw();
use IPC::Open2 qw(open2);
use LWP::UserAgent qw();
use MIME::Base64 qw(decode_base64);
use Memoize qw(memoize);
#use Memoize::Expire qw();
use DB_File;
use Pod::Usage qw(pod2usage);
use Pod::Simple::HTML qw();
use Varz qw();

use version; our $VERSION = version->declare('v0.0.1');

=pod

=head1 NAME

sharexbmc - Sharing your XBMC media just got easy.

=head1 DESCRIPTION

share|xbmc is a fun coding project I started early one morning to fill some empty time
when I couldn't sleep. More to the point though, it's trying to fill a nieche to provide
a platform agnostic, self-contained streaming web interface to XBMC that will allow
realtime transcoding of media to portable devices such as iPods, iPads and Android phones.

It is written around the lightweight Dancer web framework, XBMC's JSON API, FFMPEG, and
is packaged up neatly using Perl's awesome PAR suite.

The majority of this was written when I was either sleep deprived or drunk. Expect it
to be polished over the coming weeks and months. If you have any specific feature requests
or feedback on what has been done so far, please contact me at L<nicolaw@tfb.net>.

=head1 USAGE

 sharexbmc [OPTIONS]
     --version             Display the program version number
     --help                Display this help message
     --manual              Display the full man page
     --verbose             Increase verbosity
     --debug               Run in full debug mode
     --environment=<ENV>   Specify the environmental configuration to run
                           with. (Default to 'development' environment).
     --config=<FILENAME>   Path and filename of the config.yml config
                           file you wish to read the application
                           configuration settings from. (Optional)

=cut

# Define some useful constants
use constant IS_PAR => grep(exists $ENV{$_}, qw(PAR_0 PAR_ARGC PAR_ARGV_0 PAR_INITIALIZED PAR_PROGNAME PAR_TEMP)) ? 1 : 0;
Varz->define_varz('is_par', 'Whether we are running inside of a PAR archive or not.', IS_PAR);
use constant TEST_DB => 'test';
use constant CFG_DB => 'settings';
use constant CACHE_DB => 'cache';

# Default view and public resource paths
set views => catdir($RealBin, 'views');
set public => catdir($RealBin, 'static');

# Default an SQLite database source path and filename
#use constant DB_FILE => catfile($RealBin, 'db', fileparse(__FILE__, qr/\.(?:exe|par|out|pl)$/i).'.sqlite');
#set plugins => { Database => { driver => 'SQLite', database => DB_FILE } } ;

# Parse command line arguments with some sensible defaults
our $opt = { environment => 'development', config => catfile($RealBin, 'config.yml') };
Getopt::Long::Configure(qw(gnu_getopt auto_help auto_version));
Getopt::Long::GetOptions($opt, 'help|?', 'verbose+', 'debug+', 'manual', 'environment=s') or pod2usage(2);
pod2usage(1) if $opt->{help};
pod2usage(-exitval => 0, -verbose => 2) if $opt->{manual};

=pod

=head1 ENVIRONMENT VARIABLES

See lib/Dancer/Config.pm for a list of defaults and precedence. The following %ENV environment variables
are checked and used for default values if no other values have been specified or loaded from config.yml:

 DANCER_SERVER, DANCER_PORT, DANCER_CONTENT_TYPE, DANCER_CHARSET,
 DANCER_ACCESS_LOG, DANCER_DAEMON, DANCER_APPLANDLER,
 DANCER_WARNINGS, DANCER_AUTO_RELOAD, DANCER_ENVIRONMENT,
 PLACK_ENV

=cut

# Tell the Dancer where the app lives and load settings from config.yml.
Dancer::Config::setting('appdir', $RealBin);
Dancer::Config::setting('environment', $opt->{environment});
Dancer::Config::setting('strict_config', 1); # See lib/Dancer/Config/Object.pm
Dancer::Config::load();

config->{engines}->{template_toolkit}->{FILTERS} = { 'url_decode' =>  sub {
		my $text = shift;
		#$text =~ tr/+/ /;
		$text =~ s/%([a-fA-F0-9]{2})/chr(hex($1))/eg;
		#$text =~ s/<!--(.|\n)*-->//g;
		return $text;
	}};

# Get a full list of definitions of supported transcodable video formats
our $default_video_format = 'webm';
our $video_format = get_video_format();

# On-time application initialization: create the database
sub init_db {
	database(CACHE_DB)->do(qq/
		CREATE TABLE IF NOT EXISTS thumbnail (
			id TEXT,
			height INTEGER,
			width INTEGER,
			image BLOB,
			PRIMARY KEY (id, height, width)
			)/);
}

# Useful for debugging environmental Perl runtime problems
sub dump_useful_runtime_data {
	if (open(my $fh, '>', sprintf('packages%s.log', IS_PAR ? '-par' : ''))) {
		Varz->define('packages', 'Count of loaded Perl packages.', 0);
		for my $package (sort keys %INC) {
			Varz->inc('packages');
			say $fh $package;
		}
		close($fh);
	}
	if (open(my $fh, '>', sprintf('env%s.log', IS_PAR ? '-par' : ''))) {
		for my $variable (sort keys %ENV) {
			say $fh "$variable='$ENV{$variable}'";
		}
		close($fh);
	}
}



get '/' => sub {
	template 'index', { page_title => 'Most Recent Activity' };
};

get qr!^/stream/([a-zA-Z0-9_-]{3,16})/(.+?)(/_BrokenClientWorkaround_\.[a-zA-Z0-9]{2,4})?$! => sub {
	my ($format, $file, $client_bug_workaround) = splat;

	die "bad characters in file '$file'"
		if $file !~ /^[\/ a-z0-9_\.,\(\)\!\&\-]+$/i;

	if (!exists $video_format->{$format}) {
		warn "Was unable to find a video format definition for '$format'; defaulting to '$default_video_format' instead";
		$format = $default_video_format;
	}

	# Make sure we work around bugs in shitty web and video clients that are too retarded
	# to properly interpret and obey Content-Type MIME types or HTML5 video source tags!
	# Yes; I'm talking about you pre-iOS 5 versions and pre-Android 2.3 versions. GAH!
	# ...oh iOS doesn't actually support LIVE video streaming. Only streaming from static
	# video files. Really Apple? REALLY?! Fucking wankers.
	# http://stackoverflow.com/questions/6592485/http-live-streaming
#	if (!$client_bug_workaround) {
#		my $video_extension = $video_format->{$format}->{extension};
#		my $new_url = "/stream/$format/$file/_BrokenClientWorkaround_.$video_extension";
#		return redirect $new_url;
#	}

	# General HTML5 video streaming
	# http://diveintohtml5.info/video.html
	# http://diveintohtml5.info/video.html#video-mime-types

	# Android specific
	# http://diveintohtml5.info/video.html#android
	# http://developer.android.com/guide/appendix/media-formats.html

	# Apple iOS specific
	# http://diveintohtml5.info/video.html#ios
	# https://developer.apple.com/library/ios/DOCUMENTATION/Miscellaneous/Conceptual/iPhoneOSTechOverview/MediaLayer/MediaLayer.html
	# https://developer.apple.com/library/safari/documentation/AudioVideo/Conceptual/AirPlayGuide/PreparingYourMediaforAirPlay/PreparingYourMediaforAirPlay.html
	# http://stackoverflow.com/questions/6592485/http-live-streaming

	return send_file(
		'favicon.ico',
		streaming => 1,
		callbacks => {
			override => sub {
				my ($respond, $response) = @_;

				my @ffmpeg_args = qw(-threads 0 -i);
				push @ffmpeg_args, "'$file'";
				push @ffmpeg_args, '-sn';
				push @ffmpeg_args, @{$video_format->{$format}->{ffmpeg_args}};
				push @ffmpeg_args, '-';
				
				my $writer = $respond->([200, [
						'Content-Type' => $video_format->{$format}->{mime_type}
					]]);

				open(my $fh, '-|', join(' ', '/usr/bin/ffmpeg', @ffmpeg_args));
				my $buffer;
				while (read($fh, $buffer, 1024) ) { 
					$writer->write($buffer);
				}
				close($fh);

				#$writer->close;
			},
		},
	);
};

get '/about' => sub {
	my $p = Pod::Simple::HTML->new();
	$p->html_h_level(2);
	$p->index(0);
	$p->output_string(\my $html);
	$p->parse_file(__FILE__);
	template 'about', { page_title => 'About Share|XBMC', pod_html => $html };
};

get '/television' => sub {
	template 'television', { page_title => 'Television' };
};

get qr{^/thumbnail/(.+)$} => sub {
	my ($thumb) = splat;

	my $criteria = { id => $thumb };
	for (qw(width height)) {
		$criteria->{$_} = params->{$_} if params->{$_};
	}
	my $row = database(CACHE_DB)->quick_select('thumbnail', $criteria);

	if ($row->{image}) {
		header('Content-Type' => 'image/png');
		return $row->{image};

	} else {
		(my $url = $thumb) =~ s/%([a-fA-F0-9]{2})/chr(hex($1))/eg;
		my $ua = LWP::UserAgent->new();
		$ua->agent('Mozilla/5.0 (compatible; MSIE 8.0; Windows NT 5.1; Trident/4.0; InfoPath.2; SLCC1; .NET CLR 3.0.4506.2152; .NET CLR 3.5.30729; .NET CLR 2.0.50727)');
		my $req = HTTP::Request->new(GET => $url);
		$req->header('Referer', 'http://www.imdb.com');
		my $res = $ua->request($req);	

		if ($res->is_success) {
			database(CACHE_DB)->quick_insert('thumbnail', { id => $thumb, image => $res->content });

			if (params->{width} && params->{height}) {
				my $img_data = $res->content;
				my $image = Image::Magick->new();
				$image->BlobToImage($img_data);
				$image->Sample(width => params->{width}*1.5, height => params->{height}*1.5);
				$image->Set(quality => 30);
				$criteria->{image} = $image->ImageToBlob;
				database(CACHE_DB)->quick_insert('thumbnail', $criteria);

				header('Content-Type' => 'image/png');
				return $criteria->{image};
			}

			header('Content-Type' => 'image/png');
			return $res->content;

		} else {
			status 'not_found';
			return "File not found; ".$res->status_line;
		}
	}
};

get '/movies/:title/:year' => sub {
	my $ua = LWP::UserAgent->new();
	$ua->credentials('beren.wat.tfb.net:8080',
			config->xbmc->json_api->realm,
			config->xbmc->json_api->username,
			config->xbmc->json_api->password,
		);
	$ua->agent(config->xbmc->json_api->user_agent);

	my $object = {
		jsonrpc => "2.0", 
		id => 'libMovies',
                method  => 'VideoLibrary.GetMovies',
                params  => {
                                filter => {
					field => 'title',
					operator => 'is',
					value => params->{title},
					},
                                sort => {
					order => 'ascending',
					method => 'title',
					},
				properties => [qw(
					title genre year rating director trailer tagline plot plotoutline 
					originaltitle lastplayed playcount writer studio mpaa cast country
					imdbnumber runtime set showlink streamdetails top250 votes 
					fanart thumbnail file sorttitle resume setid dateadded tag art
					)],
				limits => {
					start => 0,
					end => 100,
					},
                        },
                };

	my $json = to_json($object, { ascii => 1, pretty => 1 });
	my $req = HTTP::Request->new(POST => config->xbmc->json_api->url);
	$req->content_type('application/json');
	$req->content($json);

	my $error_message = undef;
	my $rpc_result = undef;

	my $res = $ua->request($req);
	if ($res->is_success) {
		$rpc_result = from_json($res->content, { utf8 => 1 });
	} else {
		$error_message = $res->error_message;
	}

	template 'movie_detail', {
			page_title => params->{title}.' ('.params->{year}.')',
			rpc_client_status => $res->status_line,
			rpc_error_message => $error_message,
			rpc_result => $rpc_result,
			request_object => $object,
		};
};

#tie my %disk_cache => 'DB_File', 'disk_cache.tmp', O_CREAT|O_RDWR, 0666;
#tie my %cache => 'Memoize::Expire',
#		LIFETIME => 900,
#		NUM_USES => 100,
#		HASH => \%disk_cache;
#memoize 'get_movies', SCALAR_CACHE => [ HASH => \%cache ];

memoize('get_movies');
sub get_movies {
	my $ua = LWP::UserAgent->new();
	$ua->credentials('beren.wat.tfb.net:8080',
			config->xbmc->json_api->realm,
			config->xbmc->json_api->username,
			config->xbmc->json_api->password,
		);
	$ua->agent(config->xbmc->json_api->user_agent);

	my $object = {
		jsonrpc => "2.0", 
		id => 'libMovies',
                method  => 'VideoLibrary.GetMovies',
                params  => {
                                sort => {
					order => 'ascending',
					method => 'title',
					},
				properties => [qw(
					title genre year rating director tagline 
					mpaa country
					imdbnumber runtime set showlink top250 votes 
					sorttitle setid dateadded tag art
					)],
				limits => {
					start => 0,
					end => 5000,
					},
                        },
                };
					#start => (params->{page} * config->app->pagination->movies_per_page) - config->app->pagination->movies_per_page,
					#end => (params->{page} * config->app->pagination->movies_per_page),

	my $json = to_json($object, { ascii => 1, pretty => 1 });
	my $req = HTTP::Request->new(POST => config->xbmc->json_api->url);
	$req->content_type('application/json');
	$req->content($json);

	my $rpc_result = {};
	my $res = $ua->request($req);
	if ($res->is_success) {
		$rpc_result = from_json($res->content, { utf8 => 1 });
	} else {
		$rpc_result->{__RPC_ERROR_MESSAGE__} = $res->error_message;
	}
	$rpc_result->{__RPC_STATUS_LINE__} = $res->status_line;
	$rpc_result->{__REQUEST_OBJECT__} = $object;

	return $rpc_result;
}

get '/movies' => sub {
	my $rpc_result = get_movies();

	template 'movies', {
			page_title        => 'Movies', 
			current_page      => params->{page},
			entries_per_page  => config->app->pagination->movies_per_page,
			rpc_client_status => $rpc_result->{__RPC_STATUS_LINE__},
			rpc_error_message => $rpc_result->{__RPC_ERROR_MESSAGE__},
			request_object    => $rpc_result->{__REQUEST_OBJECT__},
			rpc_result        => $rpc_result,
		};
};

get '/music' => sub {
	template 'music', { page_title => 'Music' };
};

any ['get', 'post'] => '/search' => sub {
	template 'search', { page_title => 'Search' };
};

get '/settings' => sub {
	template 'settings', { page_title => 'Settings & Configuration' };
};

get '/varz' => sub {
	template_or_serialize 'varz' => {
		page_title => 'Variables',
		varz => Varz->varz_to_hashref(),
	};
}; 

get '/statusz' => sub {
	template_or_serialize 'statusz' => {
		page_title => 'Status',
		is_par => IS_PAR,
		packages => \%INC,
		libinc => \@INC,
		environment => \%ENV,
		flags => $opt,
		#config => config
	};
}; 

sub get_video_format {
	# FFMPEG conversion parameters for various formats
	# http://diveintohtml5.info/video.html

	# Format Name	  Extension	MIME Type
	# mpeg4		  .mp4	 	video/mp4
	# webm		  .webm		video/webm
	# vorbs		  .ogg		video/ogg
	# iphone_segment  .ts	 	video/MP2T
	# 3gp_mobile	  .3gp	 	video/3gpp
	# flash	          .flv	 	video/x-flv
	# quicktime	  .mov	 	video/quicktime
	# av_interleave   .avi	 	video/x-msvideo
	# windows_media	  .wmv	 	video/x-ms-wmv
	# iphone_index	  .m3u8	 	application/x-mpegURL

	my $video_bitrate = '400k';
	my $audio_bitrate = '48k';

	return {
	iphone_segment => {	extension => 'ts',
				mime_type => 'video/MP2T',
			ffmpeg_args => [qw(	-strict experimental
						-i_qfactor 0.71
						-qcomp 0.6
						-qmin 10
						-qmax 63
						-qdiff 4
						-trellis 0
						-vcodec libx264
						-b:v $video_bitrate
						-b:a $audio_bitrate
						-ar 22050
						-acodec aac
						-f mpegts)]},
	mpeg4 => {	extension => 'mp4',
			mime_type => 'video/mp4',
			ffmpeg_args => [qw(	-i_qfactor 0.71
						-qcomp 0.6
						-qmin 10
						-qmax 63
						-qdiff 4
						-trellis 0
						-vcodec libx264
						-b:v $video_bitrate
						-b:a $audio_bitrate
						-ar 22050
						-acodec libmp3lame
						-f mpegts)]},
	webm => {	extension => 'webm',
			mime_type => 'video/webm',
			ffmpeg_args => [qw(	-vcodec libvpx
						-b:v $video_bitrate
						-acodec libvorbis
						-ab $audio_bitrate
						-f webm)]},
	ogg => {	extension => 'ogg',
			mime_type => 'video/ogg',
			ffmpeg_args => [qw(	-vcodec libtheora
						-b:v $video_bitrate
						-acodec libvorbis
						-ab $audio_bitrate
						-f ogg)]},
	};
}

init_db();
dump_useful_runtime_data();
dance();

=pod

=head1 SEE ALSO

L<FFmpeg::Command>, L<http://xbmc.org/download/>, L<http://wiki.xbmc.org/index.php?title=Hardware>,
L<http://handbrake.fr>, L<http://sickbeard.com>, L<http://sharethe.tv>, L<http://trakt.tv>

=head1 VERSION

v0.0.1

=head1 AUTHOR

Nicola Worthington <nicolaw@cpan.org>

L<http://perlgirl.org.uk>

=head1 COPYRIGHT

Copyright 2013 Nicola Worthington.

This software is licensed under The Apache Software License, Version 2.0.

L<http://www.apache.org/licenses/LICENSE-2.0>

=cut

