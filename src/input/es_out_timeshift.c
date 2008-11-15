/*****************************************************************************
 * es_out_timeshift.c: Es Out timeshift.
 *****************************************************************************
 * Copyright (C) 2008 Laurent Aimar
 * $Id$
 *
 * Authors: Laurent Aimar < fenrir _AT_ via _DOT_ ecp _DOT_ fr>
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
#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <assert.h>
#if defined (WIN32) && !defined (UNDER_CE)
#  include <direct.h>
#endif
#ifdef HAVE_SYS_STAT_H
#   include <sys/stat.h>
#endif

#include <vlc_common.h>
#include <vlc_charset.h>

#include <vlc_input.h>
#include <vlc_es_out.h>
#include <vlc_block.h>
#include "input_internal.h"
#include "es_out.h"
#include "es_out_timeshift.h"

/*****************************************************************************
 * Local prototypes
 *****************************************************************************/

enum
{
    C_ADD,
    C_SEND,
    C_DEL,
    C_CONTROL,
};

typedef struct
{
    int     i_type;
    mtime_t i_date;
    union
    {
        struct
        {
            es_out_id_t *p_es;
            es_format_t *p_fmt;
        } add;
        struct
        {
            es_out_id_t *p_es;
        } del;
        struct
        {
            es_out_id_t *p_es;
            block_t *p_block;
        } send;
        struct
        {
            int  i_query;

            bool b_bool;
            bool *pb_bool;
            int  i_int;
            int  *pi_int;
            int64_t i_i64;
            vlc_meta_t *p_meta;
            vlc_epg_t *p_epg;
            es_out_id_t *p_es;
            es_format_t *p_fmt;
        } control;
    };
} ts_cmd_t;

struct es_out_id_t
{
    es_out_id_t *p_es;
};

struct es_out_sys_t
{
    input_thread_t *p_input;
	es_out_t       *p_out;

    /* Configuration */
    int64_t        i_tmp_size_max;    /* Maximal temporary file size in byte */
    char           *psz_tmp_path;     /* Path for temporary files */

    /* Lock for all following fields */
    vlc_mutex_t    lock;
    vlc_cond_t     wait;

    /* */
    bool           b_delayed;
    vlc_object_t   *p_thread;

    bool           b_paused;
    mtime_t        i_pause_date;

    int            i_rate;
    int            i_rate_source;
    mtime_t        i_rate_date;
    mtime_t        i_rate_delay;

    /* */
    int            i_es;
    es_out_id_t    **pp_es;

    /* */
    int            i_cmd;
    ts_cmd_t       **pp_cmd;
    mtime_t        i_cmd_delay;
};

static es_out_id_t *Add    ( es_out_t *, const es_format_t * );
static int          Send   ( es_out_t *, es_out_id_t *, block_t * );
static void         Del    ( es_out_t *, es_out_id_t * );
static int          Control( es_out_t *, int i_query, va_list );
static void         Destroy( es_out_t * );

static int          TsStart( es_out_t * );
static void         TsStop( es_out_t * );
static void         *TsRun( vlc_object_t * );

static void CmdPush( es_out_t *, const ts_cmd_t * );
static int  CmdPop( es_out_t *, ts_cmd_t * );
static void CmdClean( ts_cmd_t * );
static void cmd_cleanup_routine( void *p ) { CmdClean( p ); }

static int  CmdInitAdd    ( ts_cmd_t *, es_out_id_t *, const es_format_t *, bool b_copy );
static void CmdInitSend   ( ts_cmd_t *, es_out_id_t *, block_t * );
static int  CmdInitDel    ( ts_cmd_t *, es_out_id_t * );
static int  CmdInitControl( ts_cmd_t *, int i_query, va_list, bool b_copy );

static void CmdExecuteAdd    ( es_out_t *, ts_cmd_t * );
static int  CmdExecuteSend   ( es_out_t *, ts_cmd_t * );
static void CmdExecuteDel    ( es_out_t *, ts_cmd_t * );
static int  CmdExecuteControl( es_out_t *, ts_cmd_t * );

static void CmdCleanAdd    ( ts_cmd_t * );
static void CmdCleanSend   ( ts_cmd_t * );
static void CmdCleanControl( ts_cmd_t *p_cmd );

static char *GetTmpPath( char *psz_path );
static FILE *GetTmpFile( const char *psz_path );

/*****************************************************************************
 * input_EsOutTimeshiftNew:
 *****************************************************************************/
es_out_t *input_EsOutTimeshiftNew( input_thread_t *p_input, es_out_t *p_next_out, int i_rate )
{
    es_out_t *p_out = malloc( sizeof(*p_out) );
    if( !p_out )
        return NULL;

    es_out_sys_t *p_sys = malloc( sizeof(*p_sys) );
    if( !p_sys )
    {
        free( p_out );
        return NULL;
    }

    /* */
    p_out->pf_add     = Add;
    p_out->pf_send    = Send;
    p_out->pf_del     = Del;
    p_out->pf_control = Control;
    p_out->pf_destroy = Destroy;
    p_out->p_sys      = p_sys;
    p_out->b_sout     = p_input->p->p_sout != NULL;

    /* */
    p_sys->p_input = p_input;
    p_sys->p_out = p_next_out;
    vlc_mutex_init_recursive( &p_sys->lock );
    vlc_cond_init( &p_sys->wait );

    p_sys->b_delayed = false;
    p_sys->p_thread = NULL;
    p_sys->b_paused = false;
    p_sys->i_pause_date = -1;
    p_sys->i_rate_source =
    p_sys->i_rate        = i_rate;
    p_sys->i_rate_date = -1;
    p_sys->i_rate_delay = 0;
    p_sys->i_cmd_delay = 0;

    TAB_INIT( p_sys->i_es, p_sys->pp_es );
    TAB_INIT( p_sys->i_cmd, p_sys->pp_cmd );

    /* TODO config
     * timeshift-granularity
     * timeshift-path
     */
    p_sys->i_tmp_size_max = 50 * 1024*1024;
    p_sys->psz_tmp_path = GetTmpPath( NULL );

    return p_out;
}

/*****************************************************************************
 * Internal functions
 *****************************************************************************/
static void Destroy( es_out_t *p_out )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    if( p_sys->b_delayed )
        TsStop( p_out );

    TAB_CLEAN( p_sys->i_cmd, p_sys->pp_cmd  );

    while( p_sys->i_es > 0 )
        Del( p_out, p_sys->pp_es[0] );
    TAB_CLEAN( p_sys->i_es, p_sys->pp_es  );

    free( p_sys->psz_tmp_path );
    vlc_cond_destroy( &p_sys->wait );
    vlc_mutex_destroy( &p_sys->lock );
    free( p_sys );
    free( p_out );
}

static es_out_id_t *Add( es_out_t *p_out, const es_format_t *p_fmt )
{
    es_out_sys_t *p_sys = p_out->p_sys;
    ts_cmd_t cmd;

    es_out_id_t *p_es = malloc( sizeof( *p_es ) );
    if( !p_es )
        return NULL;

    vlc_mutex_lock( &p_sys->lock );

    if( CmdInitAdd( &cmd, p_es, p_fmt, p_sys->b_delayed ) )
    {
        vlc_mutex_unlock( &p_sys->lock );
        free( p_es );
        return NULL;
    }

    TAB_APPEND( p_sys->i_es, p_sys->pp_es, p_es );

    if( p_sys->b_delayed )
        CmdPush( p_out, &cmd );
    else
        CmdExecuteAdd( p_out, &cmd );

    vlc_mutex_unlock( &p_sys->lock );

    return p_es;
}
static int Send( es_out_t *p_out, es_out_id_t *p_es, block_t *p_block )
{
    es_out_sys_t *p_sys = p_out->p_sys;
    ts_cmd_t cmd;
    int i_ret = VLC_SUCCESS;

    vlc_mutex_lock( &p_sys->lock );

    CmdInitSend( &cmd, p_es, p_block );
    if( p_sys->b_delayed )
        CmdPush( p_out, &cmd );
    else
        i_ret = CmdExecuteSend( p_out, &cmd) ;

    vlc_mutex_unlock( &p_sys->lock );

    return i_ret;
}
static void Del( es_out_t *p_out, es_out_id_t *p_es )
{
    es_out_sys_t *p_sys = p_out->p_sys;
    ts_cmd_t cmd;

    vlc_mutex_lock( &p_sys->lock );

    CmdInitDel( &cmd, p_es );
    if( p_sys->b_delayed )
        CmdPush( p_out, &cmd );
    else
        CmdExecuteDel( p_out, &cmd );

    TAB_REMOVE( p_sys->i_es, p_sys->pp_es, p_es );

    vlc_mutex_unlock( &p_sys->lock );
}

static int ControlLockedGetEmpty( es_out_t *p_out, bool *pb_empty )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    if( p_sys->b_delayed && p_sys->i_cmd > 0 )
        *pb_empty = false;
    else
        *pb_empty = es_out_GetEmpty( p_sys->p_out );

    return VLC_SUCCESS;
}
static int ControlLockedGetWakeup( es_out_t *p_out, mtime_t *pi_wakeup )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    if( p_sys->b_delayed )
    {
        assert( !p_sys->p_input->b_can_pace_control );
        *pi_wakeup = 0;
    }
    else
    {
        *pi_wakeup = es_out_GetWakeup( p_sys->p_out );
    }

    return VLC_SUCCESS;
}
static int ControlLockedGetBuffering( es_out_t *p_out, bool *pb_buffering )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    if( p_sys->b_delayed )
        *pb_buffering = true;
    else
        *pb_buffering = es_out_GetBuffering( p_sys->p_out );

    return VLC_SUCCESS;
}
static int ControlLockedSetPauseState( es_out_t *p_out, bool b_source_paused, bool b_paused, mtime_t i_date )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    if( !p_sys->b_delayed &&
        !b_source_paused == !b_paused )
    {
        return es_out_SetPauseState( p_sys->p_out, b_source_paused, b_paused, i_date );
    }
    if( p_sys->p_input->b_can_pace_control )
    {
        /* XXX we may do it BUT it would be better to finish the clock clean up+improvments
         * and so be able to advertize correctly pace control property in access
         * module */
        msg_Err( p_sys->p_input, "EsOutTimeshift does not work with streams that have space control" );
        return VLC_EGENERIC;
    }

    int i_ret;
    if( b_paused )
    {
        assert( !b_source_paused );

        if( !p_sys->b_delayed )
            TsStart( p_out );

        i_ret = es_out_SetPauseState( p_sys->p_out, true, true, i_date );
    }
    else
    {
        i_ret = es_out_SetPauseState( p_sys->p_out, false, false, i_date );
    }

    if( !i_ret )
    {
        if( !b_paused )
        {
            assert( p_sys->i_pause_date > 0 );

            p_sys->i_cmd_delay += i_date - p_sys->i_pause_date;
        }

        p_sys->b_paused = b_paused;
        p_sys->i_pause_date = i_date;

        vlc_cond_signal( &p_sys->wait );
    }
    return i_ret;
}
static int ControlLockedSetRate( es_out_t *p_out, int i_src_rate, int i_rate )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    if( !p_sys->b_delayed &&
        i_src_rate == i_rate )
    {
        return es_out_SetRate( p_sys->p_out, i_src_rate, i_rate );
    }
    if( p_sys->p_input->b_can_pace_control )
    {
        /* XXX we may do it BUT it would be better to finish the clock clean up+improvments
         * and so be able to advertize correctly pace control property in access
         * module */
        msg_Err( p_sys->p_input, "EsOutTimeshift does not work with streams that have space control" );
        return VLC_EGENERIC;
    }

    p_sys->i_cmd_delay += p_sys->i_rate_delay;

    p_sys->i_rate_date = -1;
    p_sys->i_rate_delay = 0;
    p_sys->i_rate = i_rate;
    p_sys->i_rate_source = i_src_rate;

    if( !p_sys->b_delayed )
        TsStart( p_out );

    return es_out_SetRate( p_sys->p_out, i_rate, i_rate );
}
static int ControlLockedSetTime( es_out_t *p_out, mtime_t i_date )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    if( !p_sys->b_delayed )
        return es_out_SetTime( p_sys->p_out, i_date );

    /* TODO */
    msg_Err( p_sys->p_input, "EsOutTimeshift does not yet support time change" );
    return VLC_EGENERIC;
}
static int ControlLockedSetFrameNext( es_out_t *p_out )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    if( !p_sys->b_delayed )
        return es_out_SetFrameNext( p_sys->p_out );

    /* TODO */
    msg_Err( p_sys->p_input, "EsOutTimeshift does not yet support frame next" );
    return VLC_EGENERIC;
}

static int ControlLocked( es_out_t *p_out, int i_query, va_list args )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    switch( i_query )
    {
    /* Invalid query for this es_out level */
    case ES_OUT_SET_ES_BY_ID:
    case ES_OUT_RESTART_ES_BY_ID:
    case ES_OUT_SET_ES_DEFAULT_BY_ID:
    case ES_OUT_SET_DELAY:
    case ES_OUT_SET_RECORD_STATE:
        assert(0);
        return VLC_EGENERIC;

    /* TODO ? or to remove ? */
    case ES_OUT_GET_TS:
        return VLC_EGENERIC;

    /* Pass-through control */
    case ES_OUT_SET_ACTIVE:
    case ES_OUT_GET_ACTIVE:
    case ES_OUT_SET_MODE:
    case ES_OUT_GET_MODE:
    case ES_OUT_SET_GROUP:
    case ES_OUT_GET_GROUP:
    case ES_OUT_SET_PCR:
    case ES_OUT_SET_GROUP_PCR:
    case ES_OUT_RESET_PCR:
    case ES_OUT_SET_NEXT_DISPLAY_TIME:
    case ES_OUT_SET_GROUP_META:
    case ES_OUT_SET_GROUP_EPG:
    case ES_OUT_DEL_GROUP:
    case ES_OUT_SET_ES:
    case ES_OUT_RESTART_ES:
    case ES_OUT_SET_ES_DEFAULT:
    case ES_OUT_SET_ES_STATE:
    case ES_OUT_GET_ES_STATE:
    case ES_OUT_SET_ES_FMT:
    {
        ts_cmd_t cmd;
        if( CmdInitControl( &cmd, i_query, args, p_sys->b_delayed ) )
            return VLC_EGENERIC;
        if( p_sys->b_delayed )
        {
            CmdPush( p_out, &cmd );
            return VLC_SUCCESS;
        }
        return CmdExecuteControl( p_out, &cmd );
    }

    /* Special control */
    case ES_OUT_GET_EMPTY:
    {
        bool *pb_empty = (bool*)va_arg( args, bool* );
        return ControlLockedGetEmpty( p_out, pb_empty );
    }
    case ES_OUT_GET_WAKE_UP: /* TODO ? */
    {
        mtime_t *pi_wakeup = (mtime_t*)va_arg( args, mtime_t* );
        return ControlLockedGetWakeup( p_out, pi_wakeup );
    }
    case ES_OUT_GET_BUFFERING:
    {
        bool *pb_buffering = (bool *)va_arg( args, bool* );
        return ControlLockedGetBuffering( p_out, pb_buffering );
    }
    case ES_OUT_SET_PAUSE_STATE:
    {
        const bool b_source_paused = (bool)va_arg( args, int );
        const bool b_paused = (bool)va_arg( args, int );
        const mtime_t i_date = (mtime_t) va_arg( args, mtime_t );

        return ControlLockedSetPauseState( p_out, b_source_paused, b_paused, i_date );
    }
    case ES_OUT_SET_RATE:
    {
        const int i_src_rate = (int)va_arg( args, int );
        const int i_rate = (int)va_arg( args, int );

        return ControlLockedSetRate( p_out, i_src_rate, i_rate );
    }
    case ES_OUT_SET_TIME:
    {
        const mtime_t i_date = (mtime_t)va_arg( args, mtime_t );

        return ControlLockedSetTime( p_out, i_date );
    }
    case ES_OUT_SET_FRAME_NEXT:
    {
        return ControlLockedSetFrameNext( p_out );
    }

    default:
        msg_Err( p_sys->p_input, "Unknown es_out_Control query !" );
        assert(0);
        return VLC_EGENERIC;
    }
}
static int Control( es_out_t *p_out, int i_query, va_list args )
{
    es_out_sys_t *p_sys = p_out->p_sys;
    int i_ret;

    vlc_mutex_lock( &p_sys->lock );
    i_ret = ControlLocked( p_out, i_query, args );
    vlc_mutex_unlock( &p_sys->lock );

    return i_ret;
}

/*****************************************************************************
 *
 *****************************************************************************/
static int TsStart( es_out_t *p_out )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    assert( !p_sys->b_delayed );

    p_sys->p_thread = vlc_custom_create( p_sys->p_input, sizeof(vlc_object_t),
                                         VLC_OBJECT_GENERIC, "es out timeshift" );
    if( !p_sys->p_thread )
        return VLC_EGENERIC;

    p_sys->b_delayed = true;
    p_sys->p_thread->p_private = p_out;
    if( vlc_thread_create( p_sys->p_thread, "es out timeshift",
                           TsRun, VLC_THREAD_PRIORITY_INPUT, false ) )
    {
        msg_Err( p_sys->p_input, "cannot create input thread" );
        vlc_object_release( p_sys->p_thread );

        p_sys->b_delayed = false;
        return VLC_EGENERIC;
    }

    return VLC_SUCCESS;
}
static void TsStop( es_out_t *p_out )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    assert( p_sys->b_delayed );

    vlc_object_kill( p_sys->p_thread );
    vlc_thread_join( p_sys->p_thread );

    for( ;; )
    {
        ts_cmd_t cmd;

        if( CmdPop( p_out, &cmd ) )
            break;

        CmdClean( &cmd );
    }

    p_sys->b_delayed = false;
}
static void *TsRun( vlc_object_t *p_thread )
{
    es_out_t *p_out = p_thread->p_private;
    es_out_sys_t *p_sys = p_out->p_sys;

    for( ;; )
    {
        ts_cmd_t cmd;
        mtime_t  i_deadline;

        /* Pop a command to execute */
        vlc_mutex_lock( &p_sys->lock );
        mutex_cleanup_push( &p_sys->lock );

        while( p_sys->b_paused || CmdPop( p_out, &cmd ) )
            vlc_cond_wait( &p_sys->wait, &p_sys->lock );

        if( p_sys->i_rate_date < 0 )
            p_sys->i_rate_date = cmd.i_date;

        p_sys->i_rate_delay = 0;
        if( p_sys->i_rate_source != p_sys->i_rate )
        {
            const mtime_t i_duration = cmd.i_date - p_sys->i_rate_date;
            p_sys->i_rate_delay = i_duration * p_sys->i_rate / p_sys->i_rate_source - i_duration;
        }

        i_deadline = cmd.i_date + p_sys->i_cmd_delay + p_sys->i_rate_delay;

        if( p_sys->i_cmd_delay + p_sys->i_rate_delay < 0 )
        {
            /* TODO handle when we cannot go faster anymore */
            msg_Err( p_sys->p_input, "FIXME rate underflow" );
        }

        vlc_cleanup_run();

        /* Regulate the speed of command processing to the same one than
         * reading  */
        //fprintf( stderr, "d=%d - %d\n", (int)(p_sys->i_cmd_delay/1000), (int)( (mdate() - cmd.i_date - p_sys->i_cmd_delay)/1000) );
        vlc_cleanup_push( cmd_cleanup_routine, &cmd );

        mwait( i_deadline );

        vlc_cleanup_pop();

        /* Execute the command */
        const int canc = vlc_savecancel();

        vlc_mutex_lock( &p_sys->lock );
        switch( cmd.i_type )
        {
        case C_ADD:
            CmdExecuteAdd( p_out, &cmd );
            CmdCleanAdd( &cmd );
            break;
        case C_SEND:
            CmdExecuteSend( p_out, &cmd );
            CmdCleanSend( &cmd );
            break;
        case C_CONTROL:
            CmdExecuteControl( p_out, &cmd );
            CmdCleanControl( &cmd );
            break;
        case C_DEL:
            CmdExecuteDel( p_out, &cmd );
            break;
        default:
            assert(0);
            break;
        }
        vlc_mutex_unlock( &p_sys->lock );

        vlc_restorecancel( canc );
    }

    return NULL;
}

/*****************************************************************************
 *
 *****************************************************************************/
static void CmdPush( es_out_t *p_out, const ts_cmd_t *p_cmd )
{
    es_out_sys_t *p_sys = p_out->p_sys;
    ts_cmd_t *p_dup = malloc( sizeof(*p_dup) );

    if( p_dup )
    {
        *p_dup = *p_cmd;
        TAB_APPEND( p_sys->i_cmd, p_sys->pp_cmd, p_dup );

        vlc_cond_signal( &p_sys->wait );
    }
}
static int CmdPop( es_out_t *p_out, ts_cmd_t *p_cmd )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    if( p_sys->i_cmd <= 0 )
        return VLC_EGENERIC;

    *p_cmd = *p_sys->pp_cmd[0];

    free( p_sys->pp_cmd[0] );
    TAB_REMOVE( p_sys->i_cmd, p_sys->pp_cmd, p_sys->pp_cmd[0] );
    return VLC_SUCCESS;
}

static void CmdClean( ts_cmd_t *p_cmd )
{
    switch( p_cmd->i_type )
    {
    case C_ADD:
        CmdCleanAdd( p_cmd );
        break;
    case C_SEND:
        CmdCleanSend( p_cmd );
        break;
    case C_CONTROL:
        CmdCleanControl( p_cmd );
        break;
    case C_DEL:
        break;
    default:
        assert(0);
        break;
    }
}

static int CmdInitAdd( ts_cmd_t *p_cmd, es_out_id_t *p_es, const es_format_t *p_fmt, bool b_copy )
{
    p_cmd->i_type = C_ADD;
    p_cmd->i_date = mdate();
    p_cmd->add.p_es = p_es;
    if( b_copy )
    {
        p_cmd->add.p_fmt = malloc( sizeof(*p_fmt) );
        if( !p_cmd->add.p_fmt )
            return VLC_EGENERIC;
        es_format_Copy( p_cmd->add.p_fmt, p_fmt );
    }
    else
    {
        p_cmd->add.p_fmt = (es_format_t*)p_fmt;
    }
    return VLC_SUCCESS;
}
static void CmdExecuteAdd( es_out_t *p_out, ts_cmd_t *p_cmd )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    p_cmd->add.p_es->p_es = es_out_Add( p_sys->p_out, p_cmd->add.p_fmt );
}
static void CmdCleanAdd( ts_cmd_t *p_cmd )
{
    es_format_Clean( p_cmd->add.p_fmt );
    free( p_cmd->add.p_fmt );
}

static void CmdInitSend( ts_cmd_t *p_cmd, es_out_id_t *p_es, block_t *p_block )
{
    p_cmd->i_type = C_SEND;
    p_cmd->i_date = mdate();
    p_cmd->send.p_es = p_es;
    p_cmd->send.p_block = p_block;
}
static int CmdExecuteSend( es_out_t *p_out, ts_cmd_t *p_cmd )
{
    es_out_sys_t *p_sys = p_out->p_sys;
    block_t *p_block = p_cmd->send.p_block;

    p_cmd->send.p_block = NULL;

    if( p_block )
    {
        if( p_cmd->send.p_es->p_es )
            return es_out_Send( p_sys->p_out, p_cmd->send.p_es->p_es, p_block );
        block_Release( p_block );
    }
    return VLC_EGENERIC;
}
static void CmdCleanSend( ts_cmd_t *p_cmd )
{
    if( p_cmd->send.p_block )
        block_Release( p_cmd->send.p_block );
}

static int CmdInitDel( ts_cmd_t *p_cmd, es_out_id_t *p_es )
{
    p_cmd->i_type = C_DEL;
    p_cmd->i_date = mdate();
    p_cmd->del.p_es = p_es;
    return VLC_SUCCESS;
}
static void CmdExecuteDel( es_out_t *p_out, ts_cmd_t *p_cmd )
{
    es_out_sys_t *p_sys = p_out->p_sys;

    if( p_cmd->del.p_es->p_es )
        es_out_Del( p_sys->p_out, p_cmd->del.p_es->p_es );
    free( p_cmd->del.p_es );
}

static int CmdInitControl( ts_cmd_t *p_cmd, int i_query, va_list args, bool b_copy )
{
    p_cmd->i_type = C_CONTROL;
    p_cmd->i_date = mdate();
    p_cmd->control.i_query = i_query;
    p_cmd->control.p_meta  = NULL;
    p_cmd->control.p_epg = NULL;
    p_cmd->control.p_fmt = NULL;

    switch( i_query )
    {
    /* Pass-through control */
    case ES_OUT_SET_ACTIVE:  /* arg1= bool                     */
        p_cmd->control.b_bool = (bool)va_arg( args, int );
        break;

    case ES_OUT_GET_ACTIVE:  /* arg1= bool*                    */
        p_cmd->control.pb_bool = (bool*)va_arg( args, bool * );
        break;

    case ES_OUT_SET_MODE:    /* arg1= int                            */
    case ES_OUT_SET_GROUP:   /* arg1= int                            */
    case ES_OUT_DEL_GROUP:   /* arg1=int i_group */
        p_cmd->control.i_int = (int)va_arg( args, int );
        break;

    case ES_OUT_GET_MODE:    /* arg2= int*                           */
    case ES_OUT_GET_GROUP:   /* arg1= int*                           */
        p_cmd->control.pi_int = (int*)va_arg( args, int * );
        break;

    case ES_OUT_SET_PCR:                /* arg1=int64_t i_pcr(microsecond!) (using default group 0)*/
    case ES_OUT_SET_NEXT_DISPLAY_TIME:  /* arg1=int64_t i_pts(microsecond) */
        p_cmd->control.i_i64 = (int64_t)va_arg( args, int64_t );
        break;

    case ES_OUT_SET_GROUP_PCR:          /* arg1= int i_group, arg2=int64_t i_pcr(microsecond!)*/
        p_cmd->control.i_int = (int)va_arg( args, int );
        p_cmd->control.i_i64 = (int64_t)va_arg( args, int64_t );
        break;

    case ES_OUT_RESET_PCR:           /* no arg */
        break;

    case ES_OUT_SET_GROUP_META:  /* arg1=int i_group arg2=vlc_meta_t* */
    {
        p_cmd->control.i_int = (int)va_arg( args, int );
        vlc_meta_t *p_meta = (vlc_meta_t*)va_arg( args, vlc_meta_t * );

        if( b_copy )
        {
            p_cmd->control.p_meta = vlc_meta_New();
            if( !p_cmd->control.p_meta )
                return VLC_EGENERIC;
            vlc_meta_Merge( p_cmd->control.p_meta, p_meta );
        }
        else
        {
            p_cmd->control.p_meta = p_meta;
        }
        break;
    }

    case ES_OUT_SET_GROUP_EPG:   /* arg1=int i_group arg2=vlc_epg_t* */
    {
        p_cmd->control.i_int = (int)va_arg( args, int );
        vlc_epg_t *p_epg = (vlc_epg_t*)va_arg( args, vlc_epg_t * );

        if( b_copy )
        {
            p_cmd->control.p_epg = vlc_epg_New( p_epg->psz_name );
            if( !p_cmd->control.p_epg )
                return VLC_EGENERIC;
            for( int i = 0; i < p_epg->i_event; i++ )
            {
                vlc_epg_event_t *p_evt = p_epg->pp_event[i];

                vlc_epg_AddEvent( p_cmd->control.p_epg,
                                  p_evt->i_start, p_evt->i_duration,
                                  p_evt->psz_name,
                                  p_evt->psz_short_description, p_evt->psz_description );
            }
            vlc_epg_SetCurrent( p_cmd->control.p_epg,
                                p_epg->p_current ? p_epg->p_current->i_start : -1 );
        }
        else
        {
            p_cmd->control.p_epg = p_epg;
        }
        break;
    }

    /* Modified control */
    case ES_OUT_SET_ES:      /* arg1= es_out_id_t*                   */
    case ES_OUT_RESTART_ES:  /* arg1= es_out_id_t*                   */
    case ES_OUT_SET_ES_DEFAULT: /* arg1= es_out_id_t*                */
        p_cmd->control.p_es = (es_out_id_t*)va_arg( args, es_out_id_t * );
        break;

    case ES_OUT_SET_ES_STATE:/* arg1= es_out_id_t* arg2=bool   */
        p_cmd->control.p_es = (es_out_id_t*)va_arg( args, es_out_id_t * );
        p_cmd->control.b_bool = (bool)va_arg( args, int );
        break;

    case ES_OUT_GET_ES_STATE:/* arg1= es_out_id_t* arg2=bool*  */
        p_cmd->control.p_es = (es_out_id_t*)va_arg( args, es_out_id_t * );
        p_cmd->control.pb_bool = (bool*)va_arg( args, bool * );
        break;

    case ES_OUT_SET_ES_FMT:     /* arg1= es_out_id_t* arg2=es_format_t* */
    {
        p_cmd->control.p_es = (es_out_id_t*)va_arg( args, es_out_id_t * );
        es_format_t *p_fmt = (es_format_t*)va_arg( args, es_format_t * );

        if( b_copy )
        {
            p_cmd->control.p_fmt = malloc( sizeof(*p_fmt) );
            if( !p_cmd->control.p_fmt )
                return VLC_EGENERIC;
            es_format_Copy( p_cmd->control.p_fmt, p_fmt );
        }
        else
        {
            p_cmd->control.p_fmt = p_fmt;
        }
        break;
    }

    default:
        assert(0);
        return VLC_EGENERIC;
    }

    return VLC_SUCCESS;
}
static int CmdExecuteControl( es_out_t *p_out, ts_cmd_t *p_cmd )
{
    es_out_sys_t *p_sys = p_out->p_sys;
    const int i_query = p_cmd->control.i_query;

    switch( i_query )
    {
    /* Pass-through control */
    case ES_OUT_SET_ACTIVE:  /* arg1= bool                     */
        return es_out_Control( p_sys->p_out, i_query, p_cmd->control.b_bool );

    case ES_OUT_GET_ACTIVE:  /* arg1= bool*                    */
        return es_out_Control( p_sys->p_out, i_query, p_cmd->control.pb_bool );

    case ES_OUT_SET_MODE:    /* arg1= int                            */
    case ES_OUT_SET_GROUP:   /* arg1= int                            */
    case ES_OUT_DEL_GROUP:   /* arg1=int i_group */
        return es_out_Control( p_sys->p_out, i_query, p_cmd->control.i_int );

    case ES_OUT_GET_MODE:    /* arg2= int*                           */
    case ES_OUT_GET_GROUP:   /* arg1= int*                           */
        return es_out_Control( p_sys->p_out, i_query, p_cmd->control.pi_int );

    case ES_OUT_SET_PCR:                /* arg1=int64_t i_pcr(microsecond!) (using default group 0)*/
    case ES_OUT_SET_NEXT_DISPLAY_TIME:  /* arg1=int64_t i_pts(microsecond) */
        return es_out_Control( p_sys->p_out, i_query, p_cmd->control.i_i64 );

    case ES_OUT_SET_GROUP_PCR:          /* arg1= int i_group, arg2=int64_t i_pcr(microsecond!)*/
        return es_out_Control( p_sys->p_out, i_query, p_cmd->control.i_int, p_cmd->control.i_i64 );

    case ES_OUT_RESET_PCR:           /* no arg */
        return es_out_Control( p_sys->p_out, i_query );

    case ES_OUT_SET_GROUP_META:  /* arg1=int i_group arg2=vlc_meta_t* */
        return es_out_Control( p_sys->p_out, i_query, p_cmd->control.i_int, p_cmd->control.p_meta );

    case ES_OUT_SET_GROUP_EPG:   /* arg1=int i_group arg2=vlc_epg_t* */
        return es_out_Control( p_sys->p_out, i_query, p_cmd->control.i_int, p_cmd->control.p_epg );

    /* Modified control */
    case ES_OUT_SET_ES:      /* arg1= es_out_id_t*                   */
    case ES_OUT_RESTART_ES:  /* arg1= es_out_id_t*                   */
    case ES_OUT_SET_ES_DEFAULT: /* arg1= es_out_id_t*                */
        return es_out_Control( p_sys->p_out, i_query, p_cmd->control.p_es->p_es );

    case ES_OUT_SET_ES_STATE:/* arg1= es_out_id_t* arg2=bool   */
        return es_out_Control( p_sys->p_out, i_query, p_cmd->control.p_es->p_es, p_cmd->control.b_bool );

    case ES_OUT_GET_ES_STATE:/* arg1= es_out_id_t* arg2=bool*  */
        return es_out_Control( p_sys->p_out, i_query, p_cmd->control.p_es->p_es, p_cmd->control.pb_bool );

    case ES_OUT_SET_ES_FMT:     /* arg1= es_out_id_t* arg2=es_format_t* */
        return es_out_Control( p_sys->p_out, i_query, p_cmd->control.p_es->p_es, p_cmd->control.p_fmt );

    default:
        assert(0);
        msg_Err( p_sys->p_input, "Unknown es_out_Control query in CmdExecuteControl!" );
        return VLC_EGENERIC;
    }
}
static void CmdCleanControl( ts_cmd_t *p_cmd )
{
    if( p_cmd->control.p_meta )
        vlc_meta_Delete( p_cmd->control.p_meta );
    if( p_cmd->control.p_epg )
        vlc_epg_Delete( p_cmd->control.p_epg );
    if( p_cmd->control.p_fmt )
    {
        es_format_Clean( p_cmd->control.p_fmt );
        free( p_cmd->control.p_fmt );
    }
}


/*****************************************************************************
 * GetTmpFile/Path:
 *****************************************************************************/
static char *GetTmpPath( char *psz_path )
{
    if( psz_path && *psz_path )
    {
        /* Make sure that the path exists and is a directory */
        struct stat s;
        const int i_ret = utf8_stat( psz_path, &s );

        if( i_ret < 0 && !utf8_mkdir( psz_path, 0600 ) )
            return psz_path;
        else if( i_ret == 0 && ( s.st_mode & S_IFDIR ) )
            return psz_path;
    }
    free( psz_path );

    /* Create a suitable path */
#if defined (WIN32) && !defined (UNDER_CE)
    const DWORD dwCount = GetTempPathW( 0, NULL );
    wchar_t *psw_path = calloc( dwCount + 1, sizeof(wchar_t) );
    if( psw_path )
    {
        if( GetTempPathW( dwCount + 1, psw_path ) <= 0 )
        {
            free( psw_path );

            psw_path = _wgetcwd( NULL, 0 );
        }
    }

    psz_path = NULL;
    if( psw_path )
    {
        psz_path = FromWide( psw_path );
        while( psz_path && *psz_path && psz_path[strlen( psz_path ) - 1] == '\\' )
            psz_path[strlen( psz_path ) - 1] = '\0';

        free( psw_path );
    }

    if( !psz_path || *psz_path == '\0' )
    {
        free( psz_path );
        return strdup( "C:" );
    }
#else
    psz_path = strdup( "/tmp" );
#endif

    return psz_path;
}

static FILE *GetTmpFile( const char *psz_path )
{
    char *psz_name;
    int fd;
    FILE *f;

    /* */
    if( asprintf( &psz_name, "%s/vlc-timeshift.XXXXXX", psz_path ) < 0 )
        return NULL;

    /* */
    fd = mkstemp( psz_name );
    free( psz_name );

    if( fd < 0 )
        return NULL;

    /* */
    f = fdopen( fd, "rw+" );
    if( !f )
        close( fd );

    return f;
}
