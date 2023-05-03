#ifndef ALEPHIUM_TEMPLATE_H
#define ALEPHIUM_TEMPLATE_H

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <atomic>

#include "messages.h"
#include "uv.h"
#include "constants.h"

typedef struct mining_template_t
    {
    job_t *job;
    std::atomic<uint32_t> ref_count;
    uint64_t chain_task_count; // increase this by one everytime the template for the chain is updated
    } mining_template_t;

std::atomic<mining_template_t*> mining_templates[chain_nums] = {};
std::atomic<uint64_t> mining_counts[chain_nums] = {};
uint64_t task_counts[chain_nums] = { 0 };
bool mining_templates_initialized = false;


/*--------------------------------------------------------------------
 *
 *  FUNCTION: store_template__ref_count
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void store_template__ref_count
    (
    mining_template_t  *template_ptr,
    uint32_t            value
    )
{
atomic_store( &(template_ptr->ref_count), value );

}   /* store_template__ref_count() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: add_template__ref_count
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

uint32_t add_template__ref_count
    (
    mining_template_t  *template_ptr, 
    uint32_t            value
    )
{
return( atomic_fetch_add( &(template_ptr->ref_count), value ) );

}   /* add_template__ref_count() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: sub_template__ref_count
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

uint32_t sub_template__ref_count
    (
    mining_template_t  *template_ptr, 
    uint32_t            value
    )
{
return( atomic_fetch_sub( &(template_ptr->ref_count), value ) );

}   /* sub_template__ref_count() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: free_template
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void free_template
    (
    mining_template_t  *template_ptr
    )
{
uint32_t                old_count;

old_count = sub_template__ref_count( template_ptr, 1 );

if(old_count == 1)
    { // fetch_sub returns original value
    free_job( template_ptr->job );
    free( template_ptr );
    }

}   /* free_template() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: load_template
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

mining_template_t* load_template
    (
    ssize_t             chain_index
    )
{
return( atomic_load( &(mining_templates[chain_index]) ) );

}   /* load_template() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: store_template
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void store_template
    (
    ssize_t             chain_index, 
    mining_template_t  *new_template
    )
{
atomic_store( &(mining_templates[chain_index]), new_template );

}   /* store_template() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: update_templates
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void update_templates
    (
    job_t              *job
    )
{
mining_template_t      *new_template;
mining_template_t      *last_template;
ssize_t                 chain_index;

new_template = (mining_template_t *)malloc( sizeof( mining_template_t ) );
new_template->job = job;
store_template__ref_count( new_template, 1 ); // referred by mining_templates

chain_index = job->from_group * group_nums + job->to_group;
task_counts[ chain_index ] += 1;
new_template->chain_task_count = task_counts[ chain_index ];

// TODO: optimize with atomic_exchange
last_template = load_template( chain_index );
if (last_template) 
    {
    free_template(last_template);
    }

store_template( chain_index, new_template );

}   /* update_templates() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: expire_template_for_new_block
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

bool expire_template_for_new_block
    (
    mining_template_t  *template_ptr
    )
{
job_t                  *job;
ssize_t                 chain_index;
mining_template_t      *latest_template;

job = template_ptr->job;
chain_index = job->from_group * group_nums + job->to_group;

latest_template = load_template( chain_index );
if( latest_template ) 
    {
    store_template( chain_index, NULL );
    free_template( latest_template );
    return( true );
    } 

return( false );

}   /* expire_template_for_new_block() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: next_chain_to_mine
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

int32_t next_chain_to_mine
    (
    void
    )
{
uint64_t                least_hash_count;
uint64_t                i_hash_count;
int32_t                 i;
int32_t                 to_mine_index;

to_mine_index = -1;
least_hash_count = UINT64_MAX;

for ( i = 0; i < chain_nums; ++i )
    {
    i_hash_count = mining_counts[i].load();
    if ( load_template( i ) && ( i_hash_count < least_hash_count ) )
        {
        to_mine_index = i;
        least_hash_count = i_hash_count;
        }
    }

return( to_mine_index );

}   /* next_chain_to_mine() */

#endif /* ALEPHIUM_TEMPLATE_H */
