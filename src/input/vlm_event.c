/*****************************************************************************
 * vlm_event.c: Events
 *****************************************************************************
 * Copyright (C) 2009 Laurent Aimar
 * $Id$
 *
 * Authors: Laurent Aimar < fenrir _AT_ videolan _DOT_ org>
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

#include <vlc_common.h>
#include <vlc_vlm.h>
#include "vlm_internal.h"
#include "vlm_event.h"
#include <assert.h>

/* */
static void Trigger( vlm_t *, int i_type, int64_t id );

/*****************************************************************************
 *
 *****************************************************************************/
void vlm_SendEventMediaAdded( vlm_t *p_vlm, int64_t id )
{
    Trigger( p_vlm, VLM_EVENT_MEDIA_ADDED, id );
}
void vlm_SendEventMediaRemoved( vlm_t *p_vlm, int64_t id )
{
    Trigger( p_vlm, VLM_EVENT_MEDIA_REMOVED, id );
}
void vlm_SendEventMediaChanged( vlm_t *p_vlm, int64_t id )
{
    Trigger( p_vlm, VLM_EVENT_MEDIA_CHANGED, id );
}

void vlm_SendEventMediaInstanceStarted( vlm_t *p_vlm, int64_t id )
{
    Trigger( p_vlm, VLM_EVENT_MEDIA_INSTANCE_STARTED, id );
}
void vlm_SendEventMediaInstanceStopped( vlm_t *p_vlm, int64_t id )
{
    Trigger( p_vlm, VLM_EVENT_MEDIA_INSTANCE_STOPPED, id );
}

/*****************************************************************************
 *
 *****************************************************************************/
static void Trigger( vlm_t *p_vlm, int i_type, int64_t id )
{
    vlm_event_t event;

    event.i_type = i_type;
    event.id = id;
    var_SetAddress( p_vlm, "intf-event", &event );
}
