#ifndef ALEPHIUM_MINING_H
#define ALEPHIUM_MINING_H

#include "blake3.cu"
#include "log.h"

//#define SHOW_MINING_TIME  1

void worker_stream_callback
    (
    cudaStream_t        stream, 
    cudaError_t         status, 
    void               *data
    );

/*--------------------------------------------------------------------
 *
 *  FUNCTION: start_worker_mining
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void start_worker_mining
    (
    mining_worker_t    *worker
    )
{
cudaSetDevice( worker->device_id );

reset_worker( worker );
TRY( cudaMemcpyAsync( hasher( worker, false ), hasher( worker, true ), hasher_len( worker ), cudaMemcpyHostToDevice, worker->stream ) );

#ifdef SHOW_MINING_TIME
    cudaEvent_t         startEvent;
    cudaEvent_t         stopEvent;
    TRY( cudaEventCreate( &startEvent ) );
    TRY( cudaEventCreate( &stopEvent ) );
    TRY( cudaEventRecord( startEvent, worker->stream ) );
#endif  /* SHOW_MINING_TIME */

// blake3_hasher_mine<<<worker->grid_size, worker->block_size, 0, worker->stream>>>(worker->device_hasher);
MINER_IMPL( worker )<<<worker->grid_size, worker->block_size, 0, worker->stream>>>( worker->device_hasher.inline_hasher );

#ifdef SHOW_MINING_TIME
    TRY( cudaEventRecord( stopEvent, worker->stream ) );
#endif

TRY( cudaMemcpyAsync( hasher( worker, true ), hasher( worker, false ), hasher_len( worker ), cudaMemcpyDeviceToHost, worker->stream ) );

TRY( cudaStreamAddCallback( worker->stream, worker_stream_callback, worker, 0 ) );

#ifdef SHOW_MINING_TIME
    float               mining_time;
    TRY( cudaEventElapsedTime( &mining_time, startEvent, stopEvent ) );
    TRY( cudaEventDestroy( startEvent ) );
    TRY( cudaEventDestroy( stopEvent ) );
    LOG( " === mining time: %f\n", mining_time );
#endif  /* SHOW_MINING_TIME */

}   /* start_worker_mining() */

#endif /* ALEPHIUM_MINING_H */
