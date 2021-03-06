/*****************************************************************************
 * open.m: MacOS X module for vlc
 *****************************************************************************
 * Copyright (C) 2002-2008 the VideoLAN team
 * $Id$
 *
 * Authors: Jon Lech Johansen <jon-vl@nanocrew.net>
 *          Christophe Massiot <massiot@via.ecp.fr>
 *          Derk-Jan Hartman <thedj@users.sourceforge.net>
 *          Benjamin Pracht <bigben at videolan dot org>
 *          Felix Kühne <fkuehne at videolan dot org>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

/*****************************************************************************
 * Preamble
 *****************************************************************************/
#include <stdlib.h>                                      /* malloc(), free() */
#include <sys/param.h>                                    /* for MAXPATHLEN */
#include <string.h>

#include <paths.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <IOKit/storage/IOMedia.h>
#include <IOKit/storage/IOCDMedia.h>
#include <IOKit/storage/IODVDMedia.h>

#import "intf.h"
#import "playlist.h"
#import "open.h"
#import "output.h"
#import "eyetv.h"

#define setEyeTVUnconnected \
[o_capture_lbl setStringValue: _NS("No device connected")]; \
[o_capture_long_lbl setStringValue: _NS("VLC could not detect any EyeTV compatible device.\n\nCheck the device's connection, make sure that the latest EyeTV software is installed and try again.")]; \
[o_capture_lbl displayIfNeeded]; \
[o_capture_long_lbl displayIfNeeded]; \
[self showCaptureView: o_capture_label_view]


/*****************************************************************************
 * GetEjectableMediaOfClass
 *****************************************************************************/
NSArray *GetEjectableMediaOfClass( const char *psz_class )
{
    io_object_t next_media;
    mach_port_t master_port;
    kern_return_t kern_result;
    NSArray *o_devices = nil;
    NSMutableArray *p_list = nil;
    io_iterator_t media_iterator;
    CFMutableDictionaryRef classes_to_match;

    kern_result = IOMasterPort( MACH_PORT_NULL, &master_port );
    if( kern_result != KERN_SUCCESS )
    {
        return( nil );
    }
 
    classes_to_match = IOServiceMatching( psz_class );
    if( classes_to_match == NULL )
    {
        return( nil );
    }
 
    CFDictionarySetValue( classes_to_match, CFSTR( kIOMediaEjectableKey ),
                          kCFBooleanTrue );
 
    kern_result = IOServiceGetMatchingServices( master_port, classes_to_match,
                                                &media_iterator );
    if( kern_result != KERN_SUCCESS )
    {
        return( nil );
    }

    p_list = [NSMutableArray arrayWithCapacity: 1];
 
    next_media = IOIteratorNext( media_iterator );
    if( next_media )
    {
        char psz_buf[0x32];
        size_t dev_path_length;
        CFTypeRef str_bsd_path;
 
        do
        {
            str_bsd_path = IORegistryEntryCreateCFProperty( next_media,
                                                            CFSTR( kIOBSDNameKey ),
                                                            kCFAllocatorDefault,
                                                            0 );
            if( str_bsd_path == NULL )
            {
                IOObjectRelease( next_media );
                continue;
            }
 
            snprintf( psz_buf, sizeof(psz_buf), "%s%c", _PATH_DEV, 'r' );
            dev_path_length = strlen( psz_buf );
 
            if( CFStringGetCString( str_bsd_path,
                                    (char*)&psz_buf + dev_path_length,
                                    sizeof(psz_buf) - dev_path_length,
                                    kCFStringEncodingASCII ) )
            {
                [p_list addObject: [NSString stringWithUTF8String: psz_buf]];
            }
 
            CFRelease( str_bsd_path );
 
            IOObjectRelease( next_media );
 
        } while( ( next_media = IOIteratorNext( media_iterator ) ) );
    }
 
    IOObjectRelease( media_iterator );

    o_devices = [NSArray arrayWithArray: p_list];

    return( o_devices );
}

/*****************************************************************************
 * VLCOpen implementation
 *****************************************************************************/
@implementation VLCOpen

static VLCOpen *_o_sharedMainInstance = nil;

+ (VLCOpen *)sharedInstance
{
    return _o_sharedMainInstance ? _o_sharedMainInstance : [[self alloc] init];
}

- (id)init
{
    if( _o_sharedMainInstance) {
        [self dealloc];
    } else {
        _o_sharedMainInstance = [super init];
    }
 
    return _o_sharedMainInstance;
}

- (void)awakeFromNib
{
    intf_thread_t * p_intf = VLCIntf;

    [o_panel setTitle: _NS("Open Source")];
    [o_mrl_lbl setTitle: _NS("Media Resource Locator (MRL)")];

    [o_btn_ok setTitle: _NS("OK")];
    [o_btn_cancel setTitle: _NS("Cancel")];

    [[o_tabview tabViewItemAtIndex: 0] setLabel: _NS("File")];
    [[o_tabview tabViewItemAtIndex: 1] setLabel: _NS("Disc")];
    [[o_tabview tabViewItemAtIndex: 2] setLabel: _NS("Network")];
    [[o_tabview tabViewItemAtIndex: 3] setLabel: _NS("Capture")];

    [o_file_btn_browse setTitle: _NS("Browse...")];
    [o_file_stream setTitle: _NS("Treat as a pipe rather than as a file")];

    [o_disc_device_lbl setStringValue: _NS("Device name")];
    [o_disc_title_lbl setStringValue: _NS("Title")];
    [o_disc_chapter_lbl setStringValue: _NS("Chapter")];
    [o_disc_videots_btn_browse setTitle: _NS("Browse...")];
    [o_disc_dvd_menus setTitle: _NS("No DVD menus")];

    [[o_disc_type cellAtRow:0 column:0] setTitle: _NS("VIDEO_TS directory")];
    [[o_disc_type cellAtRow:1 column:0] setTitle: _NS("DVD")];
    [[o_disc_type cellAtRow:2 column:0] setTitle: _NS("VCD")];
    [[o_disc_type cellAtRow:3 column:0] setTitle: _NS("Audio CD")];

    [o_net_udp_port_lbl setStringValue: _NS("Port")];
    [o_net_udpm_addr_lbl setStringValue: _NS("Address")];
    [o_net_udpm_port_lbl setStringValue: _NS("Port")];
    [o_net_http_url_lbl setStringValue: _NS("URL")];

    [[o_net_mode cellAtRow:0 column:0] setTitle: _NS("UDP/RTP")];
    [[o_net_mode cellAtRow:1 column:0] setTitle: _NS("UDP/RTP Multicast")];
    [[o_net_mode cellAtRow:2 column:0] setTitle: _NS("HTTP/FTP/MMS/RTSP")];
    [o_net_timeshift_ckbox setTitle: _NS("Allow timeshifting")];

    [o_net_udp_port setIntValue: config_GetInt( p_intf, "server-port" )];
    [o_net_udp_port_stp setIntValue: config_GetInt( p_intf, "server-port" )];

    [o_eyetv_chn_bgbar setUsesThreadedAnimation: YES];

    [o_capture_mode_pop removeAllItems];
    if( MACOS_VERSION > 10.4f )
        [o_capture_mode_pop addItemWithTitle: @"iSight"];
    [o_capture_mode_pop addItemWithTitle: _NS("Screen")];
    [o_capture_mode_pop addItemWithTitle: @"EyeTV"];
    [o_screen_lbl setStringValue: _NS("Screen Capture Input")];
    [o_screen_long_lbl setStringValue: _NS("This facility allows you to process your screen's output.")];
    [o_screen_fps_lbl setStringValue: _NS("Frames per Second:")];
    [o_eyetv_currentChannel_lbl setStringValue: _NS("Current channel:")];
    [o_eyetv_previousProgram_btn setTitle: _NS("Previous Channel")];
    [o_eyetv_nextProgram_btn setTitle: _NS("Next Channel")];
    [o_eyetv_chn_status_txt setStringValue: _NS("Retrieving Channel Info...")];
    [o_eyetv_noInstance_lbl setStringValue: _NS("EyeTV is not launched")];
    [o_eyetv_noInstanceLong_lbl setStringValue: _NS("VLC could not connect to EyeTV.\nMake sure that you installed VLC's EyeTV plugin.")];
    [o_eyetv_launchEyeTV_btn setTitle: _NS("Launch EyeTV now")];
    [o_eyetv_getPlugin_btn setTitle: _NS("Download Plugin")];

    [self setSubPanel];

    [[NSNotificationCenter defaultCenter] addObserver: self
        selector: @selector(openFilePathChanged:)
        name: NSControlTextDidChangeNotification
        object: o_file_path];

    [[NSNotificationCenter defaultCenter] addObserver: self
        selector: @selector(openDiscInfoChanged:)
        name: NSControlTextDidChangeNotification
        object: o_disc_device];
    [[NSNotificationCenter defaultCenter] addObserver: self
        selector: @selector(openDiscInfoChanged:)
        name: NSControlTextDidChangeNotification
        object: o_disc_title];
    [[NSNotificationCenter defaultCenter] addObserver: self
        selector: @selector(openDiscInfoChanged:)
        name: NSControlTextDidChangeNotification
        object: o_disc_chapter];
    [[NSNotificationCenter defaultCenter] addObserver: self
        selector: @selector(openDiscInfoChanged:)
        name: NSControlTextDidChangeNotification
        object: o_disc_videots_folder];

    [[NSNotificationCenter defaultCenter] addObserver: self
        selector: @selector(openNetInfoChanged:)
        name: NSControlTextDidChangeNotification
        object: o_net_udp_port];
    [[NSNotificationCenter defaultCenter] addObserver: self
        selector: @selector(openNetInfoChanged:)
        name: NSControlTextDidChangeNotification
        object: o_net_udpm_addr];
    [[NSNotificationCenter defaultCenter] addObserver: self
        selector: @selector(openNetInfoChanged:)
        name: NSControlTextDidChangeNotification
        object: o_net_udpm_port];
    [[NSNotificationCenter defaultCenter] addObserver: self
        selector: @selector(openNetInfoChanged:)
        name: NSControlTextDidChangeNotification
        object: o_net_http_url];

    [[NSDistributedNotificationCenter defaultCenter] addObserver: self
                                                        selector: @selector(eyetvChanged:)
                                                            name: NULL
                                                          object: @"VLCEyeTVSupport"
                                              suspensionBehavior: NSNotificationSuspensionBehaviorDeliverImmediately];

    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(screenFPSfieldChanged:)
                                                 name: NSControlTextDidChangeNotification
                                               object: o_screen_fps_fld];

    /* register clicks on text fields */
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(textFieldWasClicked:)
                                                 name: @"VLCOpenTextFieldWasClicked"
                                               object: nil];
}

- (void)setSubPanel
{
    intf_thread_t * p_intf = VLCIntf;
    int i_index;
    module_config_t * p_item;

    [o_file_sub_ckbox setTitle: _NS("Load subtitles file:")];
    [o_file_sub_btn_settings setTitle: _NS("Settings...")];
    [o_file_sub_btn_browse setTitle: _NS("Browse...")];
    [o_file_sub_override setTitle: _NS("Override parametters")];
    [o_file_sub_delay_lbl setStringValue: _NS("Delay")];
    [o_file_sub_delay_stp setEnabled: NO];
    [o_file_sub_fps_lbl setStringValue: _NS("FPS")];
    [o_file_sub_fps_stp setEnabled: NO];
    [o_file_sub_encoding_lbl setStringValue: _NS("Subtitles encoding")];
    [o_file_sub_encoding_pop removeAllItems];
    [o_file_sub_size_lbl setStringValue: _NS("Font size")];
    [o_file_sub_size_pop removeAllItems];
    [o_file_sub_align_lbl setStringValue: _NS("Subtitles alignment")];
    [o_file_sub_align_pop removeAllItems];
    [o_file_sub_ok_btn setStringValue: _NS("OK")];
    [o_file_sub_font_box setTitle: _NS("Font Properties")];
    [o_file_sub_file_box setTitle: _NS("Subtitle File")];

    p_item = config_FindConfig( VLC_OBJECT(p_intf), "subsdec-encoding" );

    if( p_item )
    {
        for( i_index = 0; p_item->ppsz_list && p_item->ppsz_list[i_index];
             i_index++ )
        {
            [o_file_sub_encoding_pop addItemWithTitle:
                [NSString stringWithUTF8String: p_item->ppsz_list[i_index]]];
        }
        [o_file_sub_encoding_pop selectItemWithTitle:
                [NSString stringWithUTF8String: p_item->value.psz]];
    }

    p_item = config_FindConfig( VLC_OBJECT(p_intf), "subsdec-align" );

    if ( p_item )
    {
        for ( i_index = 0; i_index < p_item->i_list; i_index++ )
        {
            [o_file_sub_align_pop addItemWithTitle:
                [NSString stringWithUTF8String:
                p_item->ppsz_list_text[i_index]]];
        }
        [o_file_sub_align_pop selectItemAtIndex: p_item->value.i];
    }

    p_item = config_FindConfig( VLC_OBJECT(p_intf), "freetype-rel-fontsize" );

    if ( p_item )
    {
        for ( i_index = 0; i_index < p_item->i_list; i_index++ )
        {
            [o_file_sub_size_pop addItemWithTitle:
                [NSString stringWithUTF8String:
                p_item->ppsz_list_text[i_index]]];
            if ( p_item->value.i == p_item->pi_list[i_index] )
            {
                [o_file_sub_size_pop selectItemAtIndex: i_index];
            }
        }
    }
}

- (void)openTarget:(int)i_type
{
    int i_result;
    intf_thread_t * p_intf = VLCIntf;

    b_autoplay = config_GetInt( VLCIntf, "macosx-autoplay" );

    [o_tabview selectTabViewItemAtIndex: i_type];
    [o_file_sub_ckbox setState: NSOffState];
 
    i_result = [NSApp runModalForWindow: o_panel];
    [o_panel close];

    if( i_result )
    {
        NSMutableDictionary *o_dic;
        NSMutableArray *o_options = [NSMutableArray array];
        unsigned int i;

        o_dic = [NSMutableDictionary dictionaryWithObject: [o_mrl stringValue] forKey: @"ITEM_URL"];
        if( [o_file_sub_ckbox state] == NSOnState )
        {
            module_config_t * p_item;

            [o_options addObject: [NSString stringWithFormat: @"sub-file=%@", [o_file_sub_path stringValue]]];
            if( [o_file_sub_override state] == NSOnState )
            {
                [o_options addObject: [NSString stringWithFormat: @"sub-delay=%i", (int)( [o_file_sub_delay intValue] * 10 )]];
                [o_options addObject: [NSString stringWithFormat: @"sub-fps=%f", [o_file_sub_fps floatValue]]];
            }
            [o_options addObject: [NSString stringWithFormat:
                    @"subsdec-encoding=%@",
                    [o_file_sub_encoding_pop titleOfSelectedItem]]];
            [o_options addObject: [NSString stringWithFormat:
                    @"subsdec-align=%i",
                    [o_file_sub_align_pop indexOfSelectedItem]]];

            p_item = config_FindConfig( VLC_OBJECT(p_intf),
                                            "freetype-rel-fontsize" );

            if ( p_item )
            {
                [o_options addObject: [NSString stringWithFormat:
                    @"freetype-rel-fontsize=%i",
                    p_item->pi_list[[o_file_sub_size_pop indexOfSelectedItem]]]];
            }
        }
        if( [o_output_ckbox state] == NSOnState )
        {
            for (i = 0 ; i < [[o_sout_options getMRL] count] ; i++)
            {
                [o_options addObject: [NSString stringWithString:
                      [[(VLCOutput *)o_sout_options getMRL] objectAtIndex: i]]];
            }
        }
        if( [o_net_timeshift_ckbox state] == NSOnState )
        {
            [o_options addObject: [NSString stringWithString:
                                                @"access-filter=timeshift"]];
        }
        if( [[[o_tabview selectedTabViewItem] label] isEqualToString: _NS("Capture")] )
        {
            if( [[[o_capture_mode_pop selectedItem] title] isEqualToString: _NS("Screen")] )
                [o_options addObject: [NSString stringWithFormat: @"screen-fps=%i", [o_screen_fps_fld intValue]]];
        }

        /* apply the options to our item(s) */
        [o_dic setObject: (NSArray *)[o_options copy] forKey: @"ITEM_OPTIONS"];
        if( b_autoplay )
            [o_playlist appendArray: [NSArray arrayWithObject: o_dic] atPos: -1 enqueue:NO];
        else
            [o_playlist appendArray: [NSArray arrayWithObject: o_dic] atPos: -1 enqueue:YES];
    }
}

- (void)tabView:(NSTabView *)o_tv didSelectTabViewItem:(NSTabViewItem *)o_tvi
{
    NSString *o_label = [o_tvi label];

    if( [o_label isEqualToString: _NS("File")] )
    {
        [self openFilePathChanged: nil];
    }
    else if( [o_label isEqualToString: _NS("Disc")] )
    {
        [self openDiscTypeChanged: nil];
    }
    else if( [o_label isEqualToString: _NS("Network")] )
    {
        [self openNetInfoChanged: nil];
    }
    else if( [o_label isEqualToString: _NS("Capture")] )
    {
        [self openCaptureModeChanged: nil];
    }
}

- (void)openFileGeneric
{
    [self openFilePathChanged: nil];
    [self openTarget: 0];
}

- (void)openDisc
{
    [self openDiscTypeChanged: nil];
    [self openTarget: 1];
}

- (void)openNet
{
    [self openNetInfoChanged: nil];
    [self openTarget: 2];
}

- (void)openCapture
{
    [self openCaptureModeChanged: nil];
    [self showCaptureView: o_capture_label_view];
    [self openTarget: 3];
}

- (void)openFilePathChanged:(NSNotification *)o_notification
{
    NSString *o_mrl_string;
    NSString *o_filename = [o_file_path stringValue];
    NSString *o_ext = [o_filename pathExtension];
    bool b_stream = [o_file_stream state];
    BOOL b_dir = NO;
 
    [[NSFileManager defaultManager] fileExistsAtPath:o_filename isDirectory:&b_dir];

    if( b_dir )
    {
        o_mrl_string = [NSString stringWithFormat: @"directory://%@", o_filename];
    }
    else if( [o_ext isEqualToString: @"bin"] ||
        [o_ext isEqualToString: @"cue"] ||
        [o_ext isEqualToString: @"vob"] ||
        [o_ext isEqualToString: @"iso"] )
    {
        o_mrl_string = o_filename;
    }
    else
    {
        o_mrl_string = [NSString stringWithFormat: @"%s://%@",
                        b_stream ? "stream" : "file",
                        o_filename];
    }
    [o_mrl setStringValue: o_mrl_string];
}

- (IBAction)openFileBrowse:(id)sender
{
    NSOpenPanel *o_open_panel = [NSOpenPanel openPanel];
 
    [o_open_panel setAllowsMultipleSelection: NO];
    [o_open_panel setCanChooseDirectories: YES];
    [o_open_panel setTitle: _NS("Open File")];
    [o_open_panel setPrompt: _NS("Open")];

    [o_open_panel beginSheetForDirectory:nil
        file:nil
        types:nil
        modalForWindow:[sender window]
        modalDelegate: self
        didEndSelector: @selector(pathChosenInPanel:
                        withReturn:
                        contextInfo:)
        contextInfo: nil];
}

- (void)pathChosenInPanel: (NSOpenPanel *) sheet withReturn:(int)returnCode contextInfo:(void  *)contextInfo
{
    if (returnCode == NSFileHandlingPanelOKButton)
    {
        NSString *o_filename = [[sheet filenames] objectAtIndex: 0];
        [o_file_path setStringValue: o_filename];
        [self openFilePathChanged: nil];
    }
}

- (IBAction)openFileStreamChanged:(id)sender
{
    [self openFilePathChanged: nil];
}

- (IBAction)openDiscTypeChanged:(id)sender
{
    NSString *o_type;
    BOOL b_device, b_no_menus, b_title_chapter;
 
    [o_disc_device removeAllItems];
    b_title_chapter = ![o_disc_dvd_menus state];
 
    o_type = [[o_disc_type selectedCell] title];

    if ( [o_type isEqualToString: _NS("VIDEO_TS directory")] )
    {
        b_device = NO; b_no_menus = YES;
    }
    else
    {
        NSArray *o_devices;
        NSString *o_disc;
        const char *psz_class = NULL;
        b_device = YES;

        if ( [o_type isEqualToString: _NS("VCD")] )
        {
            psz_class = kIOCDMediaClass;
            o_disc = o_type;
            b_no_menus = NO; b_title_chapter = YES;
		}
        else if ( [o_type isEqualToString: _NS("Audio CD")])
        {
            psz_class = kIOCDMediaClass;
            o_disc = o_type;
            b_no_menus = NO; b_title_chapter = NO;
        }
        else
        {
            psz_class = kIODVDMediaClass;
            o_disc = o_type;
            b_no_menus = YES;
        }
 
        o_devices = GetEjectableMediaOfClass( psz_class );
        if ( o_devices != nil )
        {
            int i_devices = [o_devices count];
 
            if ( i_devices )
            {
				for( int i = 0; i < i_devices; i++ )
                {
                    [o_disc_device
                        addItemWithObjectValue: [o_devices objectAtIndex: i]];
                }

                [o_disc_device selectItemAtIndex: 0];
            }
            else
            {
                [o_disc_device setStringValue:
                    [NSString stringWithFormat: _NS("No %@s found"), o_disc]];
            }
        }
    }

    [o_disc_device setEnabled: b_device];
    [o_disc_title setEnabled: b_title_chapter];
    [o_disc_title_stp setEnabled: b_title_chapter];
    [o_disc_chapter setEnabled: b_title_chapter];
    [o_disc_chapter_stp setEnabled: b_title_chapter];
    [o_disc_videots_folder setEnabled: !b_device];
    [o_disc_videots_btn_browse setEnabled: !b_device];
    [o_disc_dvd_menus setEnabled: b_no_menus];

    [self openDiscInfoChanged: nil];
}

- (IBAction)openDiscStepperChanged:(id)sender
{
    int i_tag = [sender tag];

    if( i_tag == 0 )
    {
        [o_disc_title setIntValue: [o_disc_title_stp intValue]];
    }
    else if( i_tag == 1 )
    {
        [o_disc_chapter setIntValue: [o_disc_chapter_stp intValue]];
    }

    [self openDiscInfoChanged: nil];
}

- (void)openDiscInfoChanged:(NSNotification *)o_notification
{
    NSString *o_type;
    NSString *o_device;
    NSString *o_videots;
    NSString *o_mrl_string;
    int i_title, i_chapter;
    BOOL b_no_menus;

    o_type = [[o_disc_type selectedCell] title];
    o_device = [o_disc_device stringValue];
    i_title = [o_disc_title intValue];
    i_chapter = [o_disc_chapter intValue];
    o_videots = [o_disc_videots_folder stringValue];
    b_no_menus = [o_disc_dvd_menus state];

    if ( [o_type isEqualToString: _NS("VCD")] )
    {
        if ( [o_device isEqualToString:
                [NSString stringWithFormat: _NS("No %@s found"), o_type]] )
            o_device = @"";
        o_mrl_string = [NSString stringWithFormat: @"vcd://%@@%i:%i",
                        o_device, i_title, i_chapter];
    }
    else if ( [o_type isEqualToString: _NS("Audio CD")] )
    {
        if ( [o_device isEqualToString:
                [NSString stringWithFormat: _NS("No %@s found"), o_type]] )
            o_device = @"";
        o_mrl_string = [NSString stringWithFormat: @"cdda://%@",
                        o_device];
    }
    else if ( [o_type isEqualToString: _NS("DVD")] )
    {
        if ( [o_device isEqualToString:
                [NSString stringWithFormat: _NS("No %@s found"), o_type]] )
            o_device = @"";
        if ( b_no_menus )
            o_mrl_string = [NSString stringWithFormat: @"dvdread://%@@%i:%i-",
                            o_device, i_title, i_chapter];
        else
			o_mrl_string = [NSString stringWithFormat: @"dvdnav://%@",
                            o_device];
            
    }
    else /* VIDEO_TS folder */
    {
        if ( b_no_menus )
            o_mrl_string = [NSString stringWithFormat: @"dvdread://%@@%i:%i",
                            o_videots, i_title, i_chapter];
        else
			o_mrl_string = [NSString stringWithFormat: @"dvdnav://%@",
                            o_videots];            
    }

    [o_mrl setStringValue: o_mrl_string];
}

- (IBAction)openDiscMenusChanged:(id)sender
{
    [self openDiscInfoChanged: nil];
    [self openDiscTypeChanged: nil];
}

- (IBAction)openVTSBrowse:(id)sender
{
    NSOpenPanel *o_open_panel = [NSOpenPanel openPanel];

    [o_open_panel setAllowsMultipleSelection: NO];
    [o_open_panel setCanChooseFiles: NO];
    [o_open_panel setCanChooseDirectories: YES];
    [o_open_panel setTitle: _NS("Open VIDEO_TS Directory")];
    [o_open_panel setPrompt: _NS("Open")];

    if( [o_open_panel runModalForDirectory: nil
            file: nil types: nil] == NSOKButton )
    {
        NSString *o_dirname = [[o_open_panel filenames] objectAtIndex: 0];
        [o_disc_videots_folder setStringValue: o_dirname];
        [self openDiscInfoChanged: nil];
    }
}

- (void)textFieldWasClicked:(NSNotification *)o_notification
{
    if( [o_notification object] == o_net_udp_port )
        [o_net_mode selectCellAtRow: 0 column: 0];
    else if( [o_notification object] == o_net_udpm_addr ||
             [o_notification object] == o_net_udpm_port )
        [o_net_mode selectCellAtRow: 1 column: 0];
    else
        [o_net_mode selectCellAtRow: 2 column: 0];

    [self openNetInfoChanged: nil];
}

- (IBAction)openNetModeChanged:(id)sender
{
    if( [[sender selectedCell] tag] == 0 )
        [o_panel makeFirstResponder: o_net_udp_port];
    else if ( [[sender selectedCell] tag] == 1 )
        [o_panel makeFirstResponder: o_net_udpm_addr];
    else
        [o_panel makeFirstResponder: o_net_http_url];

    [self openNetInfoChanged: nil];
}

- (IBAction)openNetStepperChanged:(id)sender
{
    int i_tag = [sender tag];

    if( i_tag == 0 )
    {
        [o_net_udp_port setIntValue: [o_net_udp_port_stp intValue]];
        [[NSNotificationCenter defaultCenter] postNotificationName: @"VLCOpenTextFieldWasClicked"
                                                            object: o_net_udp_port];
        [o_panel makeFirstResponder: o_net_udp_port];
    }
    else if( i_tag == 1 )
    {
        [o_net_udpm_port setIntValue: [o_net_udpm_port_stp intValue]];
        [[NSNotificationCenter defaultCenter] postNotificationName: @"VLCOpenTextFieldWasClicked"
                                                            object: o_net_udpm_port];
        [o_panel makeFirstResponder: o_net_udpm_port];
    }

    [self openNetInfoChanged: nil];
}

- (void)openNetInfoChanged:(NSNotification *)o_notification
{
    NSString *o_mode;
    NSString *o_mrl_string = [NSString string];
    intf_thread_t * p_intf = VLCIntf;

    o_mode = [[o_net_mode selectedCell] title];

    if( [o_mode isEqualToString: _NS("UDP/RTP")] )
    {
        int i_port = [o_net_udp_port intValue];

        o_mrl_string = [NSString stringWithString: @"udp://"];

        if( i_port != config_GetInt( p_intf, "server-port" ) )
        {
            o_mrl_string =
                [o_mrl_string stringByAppendingFormat: @"@:%i", i_port];
        }
    }
    else if( [o_mode isEqualToString: _NS("UDP/RTP Multicast")] )
    {
        NSString *o_addr = [o_net_udpm_addr stringValue];
        int i_port = [o_net_udpm_port intValue];

        o_mrl_string = [NSString stringWithFormat: @"udp://@%@", o_addr];

        if( i_port != config_GetInt( p_intf, "server-port" ) )
        {
            o_mrl_string =
                [o_mrl_string stringByAppendingFormat: @":%i", i_port];
        }
    }
    else if( [o_mode isEqualToString: _NS("HTTP/FTP/MMS/RTSP")] )
    {
        NSString *o_url = [o_net_http_url stringValue];

        if ( ![o_url hasPrefix:@"http:"] && ![o_url hasPrefix:@"ftp:"]
              && ![o_url hasPrefix:@"mms"] && ![o_url hasPrefix:@"rtsp"] )
            o_mrl_string = [NSString stringWithFormat: @"http://%@", o_url];
        else
            o_mrl_string = o_url;
    }
    [o_mrl setStringValue: o_mrl_string];
}

- (void)openFile
{
    NSOpenPanel *o_open_panel = [NSOpenPanel openPanel];
    int i;
    b_autoplay = config_GetInt( VLCIntf, "macosx-autoplay" );
 
    [o_open_panel setAllowsMultipleSelection: YES];
    [o_open_panel setCanChooseDirectories: YES];
    [o_open_panel setTitle: _NS("Open File")];
    [o_open_panel setPrompt: _NS("Open")];
 
    if( [o_open_panel runModalForDirectory: nil
            file: nil types: nil] == NSOKButton )
    {
        NSArray *o_array = [NSArray array];
        NSArray *o_values = [[o_open_panel filenames]
                sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];

        for( i = 0; i < (int)[o_values count]; i++)
        {
            NSDictionary *o_dic;
            o_dic = [NSDictionary dictionaryWithObject:[o_values objectAtIndex:i] forKey:@"ITEM_URL"];
            o_array = [o_array arrayByAddingObject: o_dic];
        }
        if( b_autoplay )
            [o_playlist appendArray: o_array atPos: -1 enqueue:NO];
        else
            [o_playlist appendArray: o_array atPos: -1 enqueue:YES];
    }
}

- (void)showCaptureView: theView
{
    NSRect o_view_rect;
    o_view_rect = [theView frame];
    if( o_currentCaptureView )
    {
        [o_currentCaptureView removeFromSuperviewWithoutNeedingDisplay];
        [o_currentCaptureView release];
    }
    [theView setFrame: NSMakeRect( 0, 10, o_view_rect.size.width, o_view_rect.size.height)];
    [theView setNeedsDisplay: YES];
    [theView setAutoresizesSubviews: YES];
    [[[o_tabview tabViewItemAtIndex: 3] view] addSubview: theView];
    [theView displayIfNeeded];
    o_currentCaptureView = theView;
    [o_currentCaptureView retain];
}

- (IBAction)openCaptureModeChanged:(id)sender
{
    if( [[[o_capture_mode_pop selectedItem] title] isEqualToString: @"EyeTV"] )
    {
        if( [[[VLCMain sharedInstance] getEyeTVController] isEyeTVrunning] == YES )
        {
            if( [[[VLCMain sharedInstance] getEyeTVController] isDeviceConnected] == YES )
            {
                [self showCaptureView: o_eyetv_running_view];
                [self setupChannelInfo];
            }
            else
            {
                setEyeTVUnconnected;
            }
        }
        else
            [self showCaptureView: o_eyetv_notLaunched_view];
        [o_mrl setStringValue: @""];
    } 
    else if( [[[o_capture_mode_pop selectedItem] title] isEqualToString: _NS("Screen")] )
    {
        [self showCaptureView: o_screen_view];
        [o_mrl setStringValue: @"screen://"];
    }
    else if( [[[o_capture_mode_pop selectedItem] title] isEqualToString: @"iSight"] )
    {
        [o_capture_lbl setStringValue: _NS("iSight Capture Input")];
        [o_capture_long_lbl setStringValue: _NS("This facility allows you to process your iSight's input signal.\n\nNo settings are available in this version, so you will be provided a 640px*480px raw video stream.\n\nLive Audio input is not supported.")];
        [o_capture_lbl displayIfNeeded];
        [o_capture_long_lbl displayIfNeeded];
        
        [self showCaptureView: o_capture_label_view];
        [o_mrl setStringValue: @"qtcapture://"];
    }
}

- (IBAction)screenStepperChanged:(id)sender
{
    [o_screen_fps_fld setIntValue: [o_screen_fps_stp intValue]];
    [o_panel makeFirstResponder: o_screen_fps_fld];
    [o_mrl setStringValue: @"screen://"];
}

- (void)screenFPSfieldChanged:(NSNotification *)o_notification
{
    [o_screen_fps_stp setIntValue: [o_screen_fps_fld intValue]];
    if( [[o_screen_fps_fld stringValue] isEqualToString: @""] )
        [o_screen_fps_fld setIntValue: 1];
    [o_mrl setStringValue: @"screen://"];
}

- (IBAction)eyetvSwitchChannel:(id)sender
{
    if( sender == o_eyetv_nextProgram_btn )
    {
        int chanNum = [[[VLCMain sharedInstance] getEyeTVController] switchChannelUp: YES];
        [o_eyetv_channels_pop selectItemWithTag:chanNum];
        [o_mrl setStringValue: [NSString stringWithFormat:@"eyetv:// :eyetv-channel=%d", chanNum]];
    }
    else if( sender == o_eyetv_previousProgram_btn )
    {
        int chanNum = [[[VLCMain sharedInstance] getEyeTVController] switchChannelUp: NO];
        [o_eyetv_channels_pop selectItemWithTag:chanNum];
        [o_mrl setStringValue: [NSString stringWithFormat:@"eyetv:// :eyetv-channel=%d", chanNum]];
    }
    else if( sender == o_eyetv_channels_pop )
    {
        int chanNum = [[sender selectedItem] tag];
        [[[VLCMain sharedInstance] getEyeTVController] selectChannel:chanNum];
        [o_mrl setStringValue: [NSString stringWithFormat:@"eyetv:// :eyetv-channel=%d", chanNum]];
    }
    else
        msg_Err( VLCIntf, "eyetvSwitchChannel sent by unknown object" );
}

- (IBAction)eyetvLaunch:(id)sender
{
    [[[VLCMain sharedInstance] getEyeTVController] launchEyeTV];
}

- (IBAction)eyetvGetPlugin:(id)sender
{
    [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: @"http://www.videolan.org/vlc/eyetv"]];
}

- (void)eyetvChanged:(NSNotification *)o_notification
{
    if( [[o_notification name] isEqualToString: @"DeviceAdded"] )
    {
        msg_Dbg( VLCIntf, "eyetv device was added" );
        [self showCaptureView: o_eyetv_running_view];
        [self setupChannelInfo];
    }
    else if( [[o_notification name] isEqualToString: @"DeviceRemoved"] )
    {
        /* leave the channel selection like that,
         * switch to our "no device" tab */
        msg_Dbg( VLCIntf, "eyetv device was removed" );
        setEyeTVUnconnected;
    }
    else if( [[o_notification name] isEqualToString: @"PluginQuit"] )
    {
        /* switch to the "launch eyetv" tab */
        msg_Dbg( VLCIntf, "eyetv was terminated" );
        [self showCaptureView: o_eyetv_notLaunched_view];
    }
    else if( [[o_notification name] isEqualToString: @"PluginInit"] )
    {
        /* we got no device yet */
        msg_Dbg( VLCIntf, "eyetv was launched, no device yet" );
        setEyeTVUnconnected;
    }
    else
        msg_Warn( VLCIntf, "unknown external notify '%s' received", [[o_notification name] UTF8String] );
}    

/* little helper method, since this code needs to be run by multiple objects */
- (void)setupChannelInfo
{
    /* set up channel selection */
    [o_eyetv_channels_pop removeAllItems];
    [o_eyetv_chn_bgbar setHidden: NO];
    [o_eyetv_chn_bgbar animate: self];
    [o_eyetv_chn_status_txt setStringValue: _NS("Retrieving Channel Info...")];
    [o_eyetv_chn_status_txt setHidden: NO];
 
    /* retrieve info */
    NSEnumerator *channels = [[[VLCMain sharedInstance] getEyeTVController] allChannels];
    int x = -2;
    [[[o_eyetv_channels_pop menu] addItemWithTitle: _NS("Composite input")
                                               action: nil
                                        keyEquivalent: @""] setTag:x++];
    [[[o_eyetv_channels_pop menu] addItemWithTitle: _NS("S-Video input")
                                               action: nil
                                        keyEquivalent: @""] setTag:x++];
    if( channels ) 
    {
        NSString *channel;
        [[o_eyetv_channels_pop menu] addItem: [NSMenuItem separatorItem]];
        while( channel = [channels nextObject] )
        {
            /* we have to add items this way, because we accept duplicates
             * additionally, we save a bit of time */
            [[[o_eyetv_channels_pop menu] addItemWithTitle: channel
                                                   action: nil
                                            keyEquivalent: @""] setTag:++x];
        }
        /* make Tuner the default */
        [o_eyetv_channels_pop selectItemWithTag:[[[VLCMain sharedInstance] getEyeTVController] currentChannel]];
    }
 
    /* clean up GUI */
    [o_eyetv_chn_bgbar setHidden: YES];
    [o_eyetv_chn_status_txt setHidden: YES];
}

- (IBAction)subsChanged:(id)sender
{
    if ([o_file_sub_ckbox state] == NSOnState)
    {
        [o_file_sub_btn_settings setEnabled:YES];
    }
    else
    {
        [o_file_sub_btn_settings setEnabled:NO];
    }
}

- (IBAction)subSettings:(id)sender
{
    [NSApp beginSheet: o_file_sub_sheet
        modalForWindow: [sender window]
        modalDelegate: self
        didEndSelector: NULL
        contextInfo: nil];
}

- (IBAction)subFileBrowse:(id)sender
{
    NSOpenPanel *o_open_panel = [NSOpenPanel openPanel];
 
    [o_open_panel setAllowsMultipleSelection: NO];
    [o_open_panel setTitle: _NS("Open File")];
    [o_open_panel setPrompt: _NS("Open")];

    if( [o_open_panel runModalForDirectory: nil
            file: nil types: nil] == NSOKButton )
    {
        NSString *o_filename = [[o_open_panel filenames] objectAtIndex: 0];
        [o_file_sub_path setStringValue: o_filename];
    }
}

- (IBAction)subOverride:(id)sender
{
    BOOL b_state = [o_file_sub_override state];
    [o_file_sub_delay setEnabled: b_state];
    [o_file_sub_delay_stp setEnabled: b_state];
    [o_file_sub_fps setEnabled: b_state];
    [o_file_sub_fps_stp setEnabled: b_state];
}

- (IBAction)subDelayStepperChanged:(id)sender
{
    [o_file_sub_delay setIntValue: [o_file_sub_delay_stp intValue]];
}

- (IBAction)subFpsStepperChanged:(id)sender;
{
    [o_file_sub_fps setFloatValue: [o_file_sub_fps_stp floatValue]];
}

- (IBAction)subCloseSheet:(id)sender
{
    [o_file_sub_sheet orderOut:sender];
    [NSApp endSheet: o_file_sub_sheet];
}

- (IBAction)panelCancel:(id)sender
{
    [NSApp stopModalWithCode: 0];
}

- (IBAction)panelOk:(id)sender
{
    if( [[o_mrl stringValue] length] )
    {
        [NSApp stopModalWithCode: 1];
    }
    else
    {
        NSBeep();
    }
}

@end

@implementation VLCOpenTextField

- (void)mouseDown:(NSEvent *)theEvent
{
    [[NSNotificationCenter defaultCenter] postNotificationName: @"VLCOpenTextFieldWasClicked"
                                                        object: self];
    [super mouseDown: theEvent];
}

@end
