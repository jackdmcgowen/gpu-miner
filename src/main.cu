/*--------------------------------------------------------------------
 *
 *  MODULE: main.cu
 *
 *  DESCRIPTION: Main entrypoint for mining program
 *
 *------------------------------------------------------------------*/

/*--------------------------------------------------------------------
                            INCLUDES
--------------------------------------------------------------------*/

#include <assert.h>
#include <stdio.h>
#include <iostream>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <chrono>
#include <mutex>
#include <nvml.h>

#include "constants.h"
#include "uv.h"
#include "messages.h"
#include "blake3.cu"
#include "pow.h"
#include "worker.h"
#include "template.h"
#include "mining.h"
#include "getopt.h"
#include "log.h"

/*--------------------------------------------------------------------
                              MACROS
--------------------------------------------------------------------*/

#ifndef MINER_VERSION
    #define MINER_VERSION "unknown"
#endif  /* MINER_VERSION */

#define NVML_CHECK( call )                                                                                                         \
    {                                                                                                                              \
        const nvmlReturn_t error = call;                                                                                           \
        if ( error != NVML_SUCCESS )                                                                                               \
			{                                                                                                                      \
            LOGERR( "nvmlError %d (%s) calling '%s' (%s line %d)\n", error, nvmlErrorString( error ), #call, __FILE__, __LINE__ ); \
			}                                                                                                                      \
    }

/*--------------------------------------------------------------------
                              TYPES
--------------------------------------------------------------------*/

typedef std::chrono::high_resolution_clock Time;
typedef std::chrono::duration<double> duration_t;
typedef std::chrono::time_point<std::chrono::high_resolution_clock> time_point_t;


typedef struct
    {
    char                name[ 64 ];
    bool                use;
    uint32_t            ctemp;
    uint32_t            mtemp;
    uint32_t            cclock;
    uint32_t            mclock;
    uint32_t            fan;
    uint32_t            watts;
    float               eff;
    std::atomic<uint64_t>   
                        hashes;
    nvmlDevice_t        hnvml;

    } device_info;

/*--------------------------------------------------------------------
                            VARIABLES
--------------------------------------------------------------------*/

std::atomic<uint32_t>   found_solutions{ 0 };
uv_loop_t              *loop;
uv_stream_t            *tcp;
time_point_t            start_time = Time::now();
std::atomic<int>        gpu_count;
std::atomic<int>        worker_count;
std::atomic<uint64_t>   total_hashes;
int                     port = 10973;
char                    broker_ip[16];
uv_timer_t              reconnect_timer;
uv_tcp_t               *uv_socket;
uv_connect_t           *uv_connect;
std::mutex              write_mutex;
uint8_t                 write_buffer[ 4096 * 1024 ];
uint8_t                 read_buf[ 2048 * 1024 * chain_nums ];
blob_t                  read_blob = { read_buf, 0 };

device_info             devices[ max_gpu_num ];

/*--------------------------------------------------------------------
                            PROCEDURES
--------------------------------------------------------------------*/

void mine_with_timer
    (
    uv_timer_t             *timer
    );

void connect_to_broker
    (
    void
    );


/*--------------------------------------------------------------------
 *
 *  FUNCTION: setup_gpu_worker_count
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void setup_gpu_worker_count
    (
    int                 _gpu_count,
    int                 _worker_count
    )
{
gpu_count.store( _gpu_count );
worker_count.store( _worker_count );

}   /* setup_gpu_worker_count() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: on_write_end
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void on_write_end
    (
    uv_write_t         *req,
    int                 status
    )
{
if( status < 0 )
    {
    LOGERR( "error on_write_end %d\n", status );
    }
free( req );

}   /* on_write_end() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: submit_new_block
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void submit_new_block
    (
    mining_worker_t    *worker
    )
{
ssize_t                 buf_size;
uv_buf_t                buf;
uv_write_t             *write_req;

expire_template_for_new_block( load_worker__template( worker ) );
const std::lock_guard<std::mutex>
                        lock( write_mutex );

buf_size = write_new_block( worker, write_buffer );
buf = uv_buf_init( (char *)write_buffer, buf_size );
print_hex( "new solution", (uint8_t *)hasher_buf( worker, true ), 32 );

write_req = (uv_write_t *)malloc( sizeof( uv_write_t ) );
uint32_t buf_count = 1;

uv_write( write_req, tcp, &buf, buf_count, on_write_end );

found_solutions.fetch_add( 1, std::memory_order_relaxed );

}   /* submit_new_block() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: mine
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void mine
    (
    mining_worker_t    *worker
    )
{
time_point_t            start;
int32_t                 to_mine_index;

start = Time::now();
to_mine_index = next_chain_to_mine();

if( to_mine_index == -1 )
    {
    LOG( "waiting for new tasks\n" );
    worker->timer.data = worker;
    uv_timer_start( &worker->timer, mine_with_timer, 500, 0 );
    }
else
    {
    mining_counts[ to_mine_index ].fetch_add( mining_steps );
    setup_template( worker, load_template( to_mine_index ) );

    start_worker_mining( worker );

    duration_t elapsed = Time::now() - start;
    // LOG("=== mining time: %fs\n", elapsed.count());
    }

}   /* mine() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: mine_with_req
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void mine_with_req
    (
    uv_work_t              *req
    )
{
mining_worker_t            *worker;

worker = load_req_worker( req );
mine( worker );

}   /* mine_with_req() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: mine_with_async
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void mine_with_async
    (
    uv_async_t             *handle
    )
{
mining_worker_t            *worker;

worker = (mining_worker_t *)handle->data;
mine( worker );

}   /* mine_with_async() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: mine_with_timer
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void mine_with_timer
    (
    uv_timer_t             *timer
    )
{
mining_worker_t            *worker;

worker = (mining_worker_t *)timer->data;
mine( worker );

}   /* mine_with_timer() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: after_mine
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void after_mine
    (
    uv_work_t              *req,
    int                     status
    )
{
return;

}   /* after_mine() */

/*--------------------------------------------------------------------
 *
 *  FUNCTION: worker_stream_callback
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void worker_stream_callback
    (
    cudaStream_t        stream,
    cudaError_t         status,
    void               *data
    )
{
mining_worker_t        *worker;
mining_template_t      *template_ptr;
job_t                  *job;
uint32_t                chain_index;

worker = (mining_worker_t *)data;
if( hasher_found_good_hash( worker, true ) )
    {
    store_worker_found_good_hash( worker, true );
    submit_new_block( worker );
    }

template_ptr = load_worker__template( worker );

job = template_ptr->job;
chain_index = job->from_group * group_nums + job->to_group;

mining_counts[chain_index].fetch_sub( mining_steps );
mining_counts[chain_index].fetch_add( hasher_hash_count( worker, true ) );
total_hashes.fetch_add( hasher_hash_count( worker, true ) );
devices[ worker->device_id ].hashes.fetch_add( hasher_hash_count( worker, true ) );
free_template( template_ptr );
worker->async.data = worker;
uv_async_send( &(worker->async) );

}   /* worker_stream_callback() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: start_mining
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void start_mining
    (
    void
    )
{
uint32_t                i;

assert( mining_templates_initialized == true );

start_time = Time::now();

for( i = 0; i < worker_count.load(); ++i )
    {
    if (devices[ mining_workers[ i ].device_id ].use )
        {
        uv_queue_work( loop, &req[i], mine_with_req, after_mine );
        }
    }

}   /* start_mining() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: start_mining_if_needed
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void start_mining_if_needed
    (
    void
    )
{
bool                    all_initialized;
int                     i;

if( mining_templates_initialized )
    {
    return;
    }

all_initialized = true;
for( i = 0; i < chain_nums; ++i )
    {
    if( load_template( i ) == NULL )
        {
        all_initialized = false;
        break;
        }
    }

if ( all_initialized )
    {
    mining_templates_initialized = true;
    start_mining();
    }

}   /* start_mining_if_needed() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: alloc_buffer
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void alloc_buffer
    (
    uv_handle_t            *handle,
    size_t                  suggested_size,
    uv_buf_t               *buf
    )
{
buf->base = (char *)malloc( suggested_size );
buf->len = suggested_size;

}   /* alloc_buffer() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: log_hashrate
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void log_hashrate
    (
    uv_timer_t         *timer
    )
{
time_point_t            current_time;

current_time = Time::now();
if( current_time > start_time )
    {
    duration_t          elapsed;
    int                 i;

    elapsed = current_time - start_time;

    for( i = 0; i < gpu_count; ++i )
        {
        float           mh;

        NVML_CHECK( nvmlDeviceGetTemperature( devices[i].hnvml, NVML_TEMPERATURE_GPU, &devices[i].ctemp ) );
        NVML_CHECK( nvmlDeviceGetPowerUsage( devices[i].hnvml, &devices[i].watts ) );
        NVML_CHECK( nvmlDeviceGetFanSpeed( devices[i].hnvml, &devices[i].fan ) );

        devices[i].watts /= 1000; /* convert milliwatts to watts */

        mh = devices[i].hashes.load() / elapsed.count() / 1000000;
        devices[i].eff = mh / devices[i].watts;

        LOG( "GPU #%d: %s - %.0f MH/s ", i, devices[i].name, mh );
        LOG_WITHOUT_TS( "[ T:%dC, P:%dW, F:%d/%, E:%.1fMH/W ]\n", devices[i].ctemp, devices[i].watts, devices[i].fan, devices[i].eff );
        }
    LOG( "Hashrate: %.0f MH/s ", total_hashes.load() / elapsed.count() / 1000000 );
    LOG_WITHOUT_TS( "Solutions: %u\n", found_solutions.load( std::memory_order_relaxed ) );
    }

}   /* log_hashrate() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: decode_buf
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

server_message_t *decode_buf
    (
    const uv_buf_t     *buf,
    ssize_t             nread
    )
{
if( read_blob.len == 0 )
    {
    server_message_t   *message;

    read_blob.blob = (uint8_t *)buf->base;
    read_blob.len = nread;

    message = decode_server_message( &read_blob );
    if( message )
        {
        if( read_blob.len > 0 ) // some bytes left
            {
            memcpy( read_buf, read_blob.blob, read_blob.len );
            read_blob.blob = read_buf;
            }
        return( message );
        }
    else  // no bytes consumed
        {
        memcpy( read_buf, buf->base, nread );
        read_blob.blob = read_buf;
        read_blob.len = nread;
        return( NULL );
        }
    }
else
    {
    assert( read_blob.blob == read_buf );
    memcpy( read_buf + read_blob.len, buf->base, nread );
    read_blob.len += nread;
    return( decode_server_message(&read_blob ) );
    }

}   /* decode_buf() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: try_to_reconnect
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void try_to_reconnect
    (
    uv_timer_t         *timer
    )
{
read_blob.len = 0;
free( uv_socket );
free( uv_connect );
connect_to_broker();
uv_timer_stop( timer );

}   /* try_to_reconnect() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: on_read
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void on_read
    (
    uv_stream_t        *server,
    ssize_t             nread,
    const uv_buf_t     *buf
    )
{
server_message_t       *message;

if( nread < 0 )
    {
    LOGERR( "error on_read %ld: might be that the full node is not synced, or miner wallets are not setup, try to reconnect\n", nread );
    uv_timer_start( &reconnect_timer, try_to_reconnect, 5000, 0 );
    return;
    }

if( nread == 0 )
    {
    return;
    }

message = decode_buf( buf, nread );
if( message )
    {
    int                 i;

    switch( message->kind )
        {
        case JOBS:
            for ( i = 0; i < message->jobs->len; ++i )
                {
                update_templates( message->jobs->jobs[i] );
                }
            start_mining_if_needed();
            break;

        case SUBMIT_RESULT:
            LOG( "submitted: %d -> %d: %d \n", message->submit_result->from_group, message->submit_result->to_group, message->submit_result->status );
            break;

        }

    free_server_message_except_jobs( message );
    }

free( buf->base );
// uv_close( (uv_handle_t *)server, free_close_cb );

}   /* on_read() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: on_connect
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void on_connect
    (
    uv_connect_t       *req,
    int                 status
    )
{
if( status < 0 )
    {
    LOGERR( "connection error %d: might be that the full node is not reachable, try to reconnect\n", status );
    uv_timer_start( &reconnect_timer, try_to_reconnect, 5000, 0 );
    return;
    }
LOG( "the server is connected %d %p\n", status, req );

tcp = req->handle;
uv_read_start( req->handle, alloc_buffer, on_read );

}   /* on_connect() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: connect_to_broker
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

void connect_to_broker
    (
    void
    )
{
struct sockaddr_in      dest;

uv_socket = (uv_tcp_t *)malloc( sizeof(uv_tcp_t) );
uv_tcp_init( loop, uv_socket );
uv_tcp_nodelay( uv_socket, 1 );
uv_connect = (uv_connect_t *)malloc( sizeof(uv_connect_t) );

uv_ip4_addr( broker_ip, port, &dest );
uv_tcp_connect( uv_connect, uv_socket, (const struct sockaddr *)&dest, on_connect );

}   /* connect_to_broker() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: is_valid_ip_address
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

bool is_valid_ip_address
    (
    char               *ip_address
    )
{
struct sockaddr_in      sa;
int                     result;

result = inet_pton( AF_INET, ip_address, &(sa.sin_addr) );
return( result != 0 );

}   /* is_valid_ip_address() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: hostname_to_ip
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

int hostname_to_ip
    (
    char               *ip_address,
    char               *hostname
    )
{
struct addrinfo         hints;
struct addrinfo        *servinfo;
struct sockaddr_in     *h;
int                     res;

memset( &hints, 0, sizeof( hints ) );
hints.ai_family = AF_INET;
hints.ai_socktype = SOCK_STREAM;

res = getaddrinfo( hostname, NULL, &hints, &servinfo );
if( res != 0 )
    {
    LOGERR( "getaddrinfo: %s\n", gai_strerror( res ) );
    return( 1 );
    }

h = (struct sockaddr_in *)servinfo->ai_addr;
strcpy( ip_address, inet_ntoa( h->sin_addr ) );

freeaddrinfo( servinfo );
return( 0 );

}   /* hostname_to_ip() */


/*--------------------------------------------------------------------
 *
 *  FUNCTION: main
 *
 *  DESCRIPTION:
 *
 *------------------------------------------------------------------*/

int main
    (
    int                 argc,
    char              **argv
    )
{
/*--------------------------------------------------------------------
Local variables
--------------------------------------------------------------------*/
int                     gpu_count;
int                     command;
uv_timer_t              log_timer;
int                     i;
#ifdef _WIN32
    WSADATA             wsa;
    int                 rc;
#endif  /* _WIN32 */

/*--------------------------------------------------------------------
Initialize
--------------------------------------------------------------------*/
setbuf( stdout, NULL );

#ifdef _WIN32
    // current winsocket version is 2.2
    rc = WSAStartup( MAKEWORD( 2, 2 ), &wsa );
    if( rc != 0 )
        {
        LOGERR( "Initialize winsock failed: %d\n", rc );
        exit( 1 );
        }
#endif  /* _WIN32 */

NVML_CHECK( nvmlInit() );

LOG( "Running gpu-miner version : %s\n", MINER_VERSION );

gpu_count = 0;
cudaGetDeviceCount( &gpu_count );
LOG( "GPU count: %d\n", gpu_count );
memset( &devices, 0, sizeof(device_info) * max_gpu_num );
for( i = 0; i < gpu_count; ++i )
    {
    cudaDeviceProp              prop;

    cudaGetDeviceProperties( &prop, i );
    strcpy_s( devices[i].name, 64, prop.name );

    NVML_CHECK( nvmlDeviceGetHandleByIndex( i, &devices[i].hnvml ) );
    //NVML_CHECK( nvmlDeviceGetClock( devices[i].hnvml, NVML_CLOCK_GRAPHICS, NVML_CLOCK_ID_CURRENT, &devices[i].cclock ) );
    //NVML_CHECK( nvmlDeviceGetClock( devices[i].hnvml, NVML_CLOCK_MEM,      NVML_CLOCK_ID_CURRENT, &devices[i].mclock ) );
    devices[i].use = true;

    LOG("GPU #%d - %s - #%d cores \n", i, devices[i].name, get_device_cores( i ) );
    }

strcpy( broker_ip, "127.0.0.1" );

while( ( command = getopt(argc, argv, "p:g:a:" ) ) != -1 )
    {
    switch( command )
        {
        case 'p':
            port = atoi( optarg );
            break;

        case 'a':
            if ( is_valid_ip_address( optarg ) )
                {
                strcpy( broker_ip, optarg );
                }
            else
                {
                hostname_to_ip( broker_ip, optarg );
                }
            break;

        case 'g':
            for ( i = 0; i < gpu_count; ++i )
                {
                devices[i].use = false;
                }
            --optind;
            for ( ; optind < argc && *argv[optind] != '-'; ++optind )
                {
                int             device;

                device = atoi( argv[ optind ] );
                if( device < 0 || device >= gpu_count )
                    {
                    LOGERR( "Invalid gpu index %d\n", device );
                    exit( 1 );
                    }
                devices[ device ].use = true;
                }
            break;

        default:
            LOGERR( "Invalid command %c\n", command );
            exit( 1 );
        }
    }

LOG( "will connect to broker @%s:%d\n", broker_ip, port );

#ifdef __linux__
    signal( SIGPIPE, SIG_IGN );
#endif

mining_workers_init( gpu_count );
setup_gpu_worker_count( gpu_count, gpu_count * parallel_mining_works_per_gpu );

loop = uv_default_loop();
uv_timer_init( loop, &reconnect_timer );
connect_to_broker();

for( i = 0; i < worker_count; ++i )
    {
    uv_async_init( loop, &( mining_workers[ i ].async ), mine_with_async );
    uv_timer_init( loop, &( mining_workers[ i ].timer ) );
    }

uv_timer_init( loop, &log_timer );
uv_timer_start( &log_timer, log_hashrate, 5000, 20000 );

uv_run( loop, UV_RUN_DEFAULT );

NVML_CHECK( nvmlShutdown() );

return( 0 );

}   /* main() */
