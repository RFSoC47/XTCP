/* Linux TCP payload measurement for the XTCP reference endpoint. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/tcp.h>
#include <netinet/in.h>
#include <poll.h>
#include <sched.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define CHUNK (255u*4096u)
#ifdef XTCP_TEST_64_GIB
#define MAX_BYTES (UINT64_C(64)*1024*1024*1024)
#else
#define MAX_BYTES (UINT64_C(32)*1024*1024*1024)
#endif
typedef struct {
    int fd, mode;
    uint64_t count,start_ns,deadline_ns;
    unsigned char *pattern;
    atomic_ullong sent,received;
    atomic_int stop,finished;
    pthread_mutex_t lock;
    pthread_cond_t condition;
    FILE *progress;
    char error[192];
    uint64_t mismatch_offset;
    struct tcp_info initial,final;
    socklen_t initial_len,final_len;
} Context;
static volatile sig_atomic_t interrupted;

/* Optional receiver/sender placement for a controlled two-P-core comparison. */
static int select_cpu(const char *option) {
    const char *s=getenv(option);
    if(!s)return 0;
    char *end=NULL;long value=strtol(s,&end,10);
    if(!*s || *end || value<0 || value>7){errno=EINVAL;return -1;}
    cpu_set_t cpus;CPU_ZERO(&cpus);CPU_SET((int)value,&cpus);
    return sched_setaffinity(0,sizeof(cpus),&cpus);
}

/** @brief Monotonic timestamp shared with Python time.monotonic_ns. @retval ns Timestamp. */
static uint64_t mono_ns(void) {
    struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);
    return (uint64_t)t.tv_sec*UINT64_C(1000000000)+(uint64_t)t.tv_nsec;
}
/** @brief Request bounded cancellation. @param sig Signal number. */
static void on_signal(int sig) { interrupted=sig; }
/** @brief Keep the first failure and stop the peer worker. @param c Context. @param why Description. @param number errno or zero. */
static void fail(Context *c,const char *why,int number) {
    pthread_mutex_lock(&c->lock);
    if(!c->error[0]) snprintf(c->error,sizeof(c->error),"%s%s%s",why,number?": ":"",number?strerror(number):"");
    atomic_store(&c->stop,1);pthread_mutex_unlock(&c->lock);
}
/** @brief Check explicit deadline/cancellation. @param c Context. @retval int Nonzero while running. */
static int running(Context *c) {
    if(interrupted) fail(c,"signal",0);
    if(mono_ns()>c->deadline_ns) fail(c,"deadline",0);
    return !atomic_load(&c->stop);
}
/** @brief Read the kernel-length-qualified TCP_INFO struct. @param fd Socket. @param t Destination. @param n Returned length. @retval int Zero on success. */
static int tcp_info_read(int fd,struct tcp_info *t,socklen_t *n) {
    memset(t,0,sizeof(*t));*n=sizeof(*t);return getsockopt(fd,IPPROTO_TCP,TCP_INFO,t,n);
}
/** @brief Emit a JSON string with escaping. @param f Output. @param s String. */
static void json_string(FILE *f,const char *s) {
    fputc('"',f);for(;*s;s++){unsigned char b=(unsigned char)*s;
        if(b=='"'||b=='\\') fprintf(f,"\\%c",b);else if(b<32) fprintf(f,"\\u%04x",b);else fputc(b,f);
    }fputc('"',f);
}
/** @brief Emit only TCP_INFO fields supported by returned length. @param f Output. @param t Data. @param n Kernel byte count. */
static void info_json(FILE *f,const struct tcp_info *t,socklen_t n) {
    fprintf(f,"{\"length\":%u",(unsigned)n);
#define INFO(field) do {fprintf(f,",\"" #field "\":"); if(n>=offsetof(struct tcp_info,field)+sizeof(t->field)) fprintf(f,"%" PRIu64,(uint64_t)t->field);else fputs("null",f);}while(0)
    INFO(tcpi_state);INFO(tcpi_options);INFO(tcpi_rto);INFO(tcpi_ato);INFO(tcpi_snd_mss);INFO(tcpi_rcv_mss);
    INFO(tcpi_unacked);INFO(tcpi_lost);INFO(tcpi_retrans);INFO(tcpi_rtt);INFO(tcpi_rttvar);INFO(tcpi_snd_cwnd);
    INFO(tcpi_snd_ssthresh);INFO(tcpi_rcv_space);INFO(tcpi_total_retrans);INFO(tcpi_pacing_rate);
    INFO(tcpi_bytes_acked);INFO(tcpi_bytes_received);INFO(tcpi_segs_out);INFO(tcpi_segs_in);
    INFO(tcpi_notsent_bytes);INFO(tcpi_min_rtt);INFO(tcpi_data_segs_in);INFO(tcpi_data_segs_out);
    INFO(tcpi_delivery_rate);INFO(tcpi_busy_time);INFO(tcpi_rwnd_limited);INFO(tcpi_sndbuf_limited);
    INFO(tcpi_bytes_sent);INFO(tcpi_bytes_retrans);INFO(tcpi_dsack_dups);INFO(tcpi_reord_seen);INFO(tcpi_rcv_ooopack);INFO(tcpi_snd_wnd);
#undef INFO
    fprintf(f,",\"snd_wscale\":%u,\"rcv_wscale\":%u}",(unsigned)t->tcpi_snd_wscale,(unsigned)t->tcpi_rcv_wscale);
}
/** @brief Match a stream slice independently of socket chunk boundaries. @param p Expected repeating bytes. @param data Slice. @param length Bytes. @param offset Stream offset. @retval int Zero for equality. */
static int compare_stream(const unsigned char *p,const unsigned char *data,size_t length,uint64_t offset) {
    return memcmp(data,p+(offset%255),length);
}
/** @brief Transmit exactly count bytes with partial-write handling. @param arg Context. @retval pointer NULL. */
static void *send_loop(void *arg) {
    Context *c=arg;uint64_t sent=0;
    if(select_cpu("XTCP_SENDER_CPU")){fail(c,"sender CPU affinity",errno);return NULL;}
    while(sent<c->count&&running(c)) {
        size_t length=(size_t)((c->count-sent)>CHUNK?CHUNK:c->count-sent);
        ssize_t n=send(c->fd,c->pattern+(sent%255),length,MSG_NOSIGNAL);
        if(n<0){if(errno==EINTR||errno==EAGAIN||errno==EWOULDBLOCK)continue;fail(c,"send",errno);break;}
        if(n==0){fail(c,"zero send",0);break;}
        sent+=(uint64_t)n;atomic_store(&c->sent,sent);
    }
    return NULL;
}
/** @brief Receive and compare all requested bytes. @param c Context. */
static void receive_loop(Context *c) {
    unsigned char *data=malloc(CHUNK);if(!data){fail(c,"receive malloc",errno);return;}
    uint64_t got=0;
    while(got<c->count&&running(c)) {
        size_t length=(size_t)((c->count-got)>CHUNK?CHUNK:c->count-got);
        ssize_t n=recv(c->fd,data,length,0);
        if(n<0){if(errno==EINTR||errno==EAGAIN||errno==EWOULDBLOCK)continue;fail(c,"recv",errno);break;}
        if(n==0){fail(c,"early EOF",0);break;}
        if(compare_stream(c->pattern,data,(size_t)n,got)) {
            size_t i=0;while(i<(size_t)n&&data[i]==c->pattern[got%255+i])i++;
            c->mismatch_offset=got+i;fail(c,"payload mismatch",0);break;
        }
        got+=(uint64_t)n;atomic_store(&c->received,got);
    }
    free(data);
}
/** @brief Sample TCP_INFO once per second without a packet capture. @param arg Context. @retval pointer NULL. */
static void *sample_loop(void *arg) {
    Context *c=arg;
    while(!atomic_load(&c->finished)) {
        struct tcp_info t;socklen_t n;
        if(tcp_info_read(c->fd,&t,&n)==0) {
            fprintf(c->progress,"{\"mono_ns\":%" PRIu64 ",\"sent\":%llu,\"received\":%llu,\"tcp\":",mono_ns(),
                (unsigned long long)atomic_load(&c->sent),(unsigned long long)atomic_load(&c->received));
            info_json(c->progress,&t,n);fputs("}\n",c->progress);fflush(c->progress);
        }
        struct timespec until;clock_gettime(CLOCK_REALTIME,&until);until.tv_sec++;
        pthread_mutex_lock(&c->lock);
        if(!atomic_load(&c->finished)) pthread_cond_timedwait(&c->condition,&c->lock,&until);
        pthread_mutex_unlock(&c->lock);
    }
    return NULL;
}
/** @brief Connect under a three-second bound then restore blocking IO. @param fd Socket. @param peer Address. @retval int Zero on success. */
static int bounded_connect(int fd,struct sockaddr_in *peer) {
    int flags=fcntl(fd,F_GETFL);if(flags<0||fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0)return -1;
    int result=connect(fd,(struct sockaddr *)peer,sizeof(*peer));
    if(result<0&&errno==EINPROGRESS){struct pollfd p={fd,POLLOUT,0};result=poll(&p,1,3000);
        if(result>0){int error=0;socklen_t n=sizeof(error);if(getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&n)<0)return -1;
            if(error){errno=error;return -1;}result=0;
        }else {errno=ETIMEDOUT;return -1;}
    }
    if(result<0)return -1;
    return fcntl(fd,F_SETFL,flags);
}
/** @brief Convert a timeval to seconds. @param t Time. @retval double Seconds. */
static double tv_seconds(struct timeval t) {return (double)t.tv_sec+(double)t.tv_usec/1e6;}
/** @brief Check stream verifier offsets/corruption and estimate local compare capacity. @retval int Zero on pass. */
static int selftest(void) {
    unsigned char *p=malloc(CHUNK+255),*d=malloc(CHUNK);if(!p||!d)return 2;
    for(size_t i=0;i<CHUNK+255;i++)p[i]=(unsigned char)(i%255+1);
    unsigned cases=0;
    for(unsigned offset=0;offset<255;offset++){
        size_t n=4099+offset;memcpy(d,p+offset,n);
        if(compare_stream(p,d,n,offset))return 3;
        d[n/2]^=0x80;if(!compare_stream(p,d,n,offset))return 4;cases+=2;
    }
    memcpy(d,p,CHUNK);uint64_t start=mono_ns(),bytes=0;volatile unsigned result=0;
    for(unsigned i=0;i<16384;i++){d[CHUNK-1]=p[CHUNK-1];result|=(unsigned)compare_stream(p,d,CHUNK,0);bytes+=CHUNK;}
    uint64_t end=mono_ns();
    printf("{\"status\":\"PASS\",\"pure_pattern_cases\":%u,\"compare_bytes\":%" PRIu64 ",\"seconds\":%.9f,\"compare_gbps\":%.6f,\"guard\":%u}\n",
        cases,bytes,(end-start)/1e9,bytes*8.0/(double)(end-start),result);
    free(p);free(d);return result?5:0;
}
/** @brief Bounded raw TCP CLI; test data only. @param argc Count. @param argv Arguments. @retval int Zero only on complete integrity/ACK gate. */
int main(int argc,char **argv) {
    if(argc==2&&!strcmp(argv[1],"--selftest"))return selftest();
    if(argc!=8&&argc!=9){fprintf(stderr,"usage: mode peer bind port bytes deadline output [sockbuf]\n");return 2;}
    Context c={.fd=-1,.mismatch_offset=UINT64_MAX};pthread_mutex_init(&c.lock,NULL);pthread_cond_init(&c.condition,NULL);
    if(select_cpu("XTCP_RECEIVER_CPU")){perror("receiver CPU affinity");return 2;}
    c.mode=!strcmp(argv[1],"receive")?1:!strcmp(argv[1],"send")?2:!strcmp(argv[1],"echo")?3:0;
    char *end=NULL;errno=0;c.count=strtoull(argv[5],&end,10);
    if(errno||!end||*end||!c.count||c.count>MAX_BYTES||!c.mode)return 2;
    double deadline=strtod(argv[6],&end);if(!end||*end||!(deadline>=1&&deadline<=180))return 2;
    long port=strtol(argv[4],&end,10);if(!end||*end||port<1||port>65535)return 2;
    long sockbuf=argc==9?strtol(argv[8],&end,10):0;if(sockbuf<0||sockbuf>4*1024*1024||(argc==9&&*end))return 2;
    FILE *output=fopen(argv[7],"wx");if(!output){perror("exclusive output");return 2;}
    char progress_path[4096];if(snprintf(progress_path,sizeof(progress_path),"%s.progress.jsonl",argv[7])>=(int)sizeof(progress_path)){fclose(output);return 2;}
    c.progress=fopen(progress_path,"wx");if(!c.progress){fclose(output);return 2;}
    c.pattern=malloc(CHUNK+255);if(!c.pattern){fclose(output);fclose(c.progress);return 2;}
    for(size_t i=0;i<CHUNK+255;i++)c.pattern[i]=(unsigned char)(i%255+1);
    signal(SIGPIPE,SIG_IGN);signal(SIGTERM,on_signal);signal(SIGINT,on_signal);
    int rcv_start=0,snd_start=0,rcv_final=0,snd_final=0;uint64_t data_end=0,end_ns=0;
    struct rusage usage0={0},usage1={0};pthread_t sender,sampler;int sender_live=0,sampler_live=0;
    c.fd=socket(AF_INET,SOCK_STREAM,0);if(c.fd<0){fail(&c,"socket",errno);goto finish;}
    struct timeval timeout={1,0};int one=1;
    if(setsockopt(c.fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout))||setsockopt(c.fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout))||
       setsockopt(c.fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one))){fail(&c,"socket options",errno);goto finish;}
    if(sockbuf){int size=(int)sockbuf;if(setsockopt(c.fd,SOL_SOCKET,SO_RCVBUF,&size,sizeof(size))||setsockopt(c.fd,SOL_SOCKET,SO_SNDBUF,&size,sizeof(size))){fail(&c,"socket buffer",errno);goto finish;}}
    struct sockaddr_in local={.sin_family=AF_INET},peer={.sin_family=AF_INET,.sin_port=htons((uint16_t)port)};
    if(inet_pton(AF_INET,argv[3],&local.sin_addr)!=1||inet_pton(AF_INET,argv[2],&peer.sin_addr)!=1){fail(&c,"IP parse",0);goto finish;}
    const char *source_port=getenv("XTCP_CLIENT_PORT");
    if(source_port){
        char *tail=NULL;long n=strtol(source_port,&tail,10);
        if(!*source_port || *tail || n<0 || n>65535){fail(&c,"invalid TCP client port",0);goto finish;}
        local.sin_port=htons((uint16_t)n);
    }
    if(bind(c.fd,(struct sockaddr *)&local,sizeof(local))){fail(&c,"bind",errno);goto finish;}
    if(bounded_connect(c.fd,&peer)){fail(&c,"connect",errno);goto finish;}
    if(tcp_info_read(c.fd,&c.initial,&c.initial_len)){fail(&c,"TCP_INFO initial",errno);goto finish;}
    if(c.initial_len<offsetof(struct tcp_info,tcpi_bytes_acked)+sizeof(c.initial.tcpi_bytes_acked)){fail(&c,"TCP_INFO too short",0);goto finish;}
    socklen_t optlen=sizeof(int);getsockopt(c.fd,SOL_SOCKET,SO_RCVBUF,&rcv_start,&optlen);optlen=sizeof(int);getsockopt(c.fd,SOL_SOCKET,SO_SNDBUF,&snd_start,&optlen);
    getrusage(RUSAGE_SELF,&usage0);c.start_ns=mono_ns();c.deadline_ns=c.start_ns+(uint64_t)(deadline*1e9);
    if(pthread_create(&sampler,NULL,sample_loop,&c)){fail(&c,"sample thread",0);goto finish;}sampler_live=1;
    if(c.mode==3){if(pthread_create(&sender,NULL,send_loop,&c)){fail(&c,"send thread",0);goto finish;}sender_live=1;}
    if(c.mode==2)send_loop(&c);else receive_loop(&c);
    if(atomic_load(&c.stop))shutdown(c.fd,SHUT_RDWR);
    if(sender_live){pthread_join(sender,NULL);sender_live=0;}
    data_end=mono_ns();
    if(c.mode!=1&&!atomic_load(&c.stop)){
        while(running(&c)){
            struct tcp_info t;socklen_t n;if(tcp_info_read(c.fd,&t,&n)){fail(&c,"TCP_INFO drain",errno);break;}
            if(t.tcpi_bytes_acked-c.initial.tcpi_bytes_acked>=c.count)break;
            struct timespec delay={0,1000000};nanosleep(&delay,NULL);
        }
    }
    end_ns=mono_ns();getrusage(RUSAGE_SELF,&usage1);
finish:
    atomic_store(&c.finished,1);pthread_mutex_lock(&c.lock);pthread_cond_broadcast(&c.condition);pthread_mutex_unlock(&c.lock);
    if(atomic_load(&c.stop)&&c.fd>=0)shutdown(c.fd,SHUT_RDWR);
    if(sender_live)pthread_join(sender,NULL);
    if(sampler_live)pthread_join(sampler,NULL);
    if(c.fd>=0){tcp_info_read(c.fd,&c.final,&c.final_len);socklen_t n=sizeof(int);getsockopt(c.fd,SOL_SOCKET,SO_RCVBUF,&rcv_final,&n);n=sizeof(int);getsockopt(c.fd,SOL_SOCKET,SO_SNDBUF,&snd_final,&n);}
    uint64_t sent=atomic_load(&c.sent),received=atomic_load(&c.received);
    int pass=!c.error[0]&&((c.mode==1&&sent==0&&received==c.count)||(c.mode==2&&sent==c.count&&received==0)||(c.mode==3&&sent==c.count&&received==c.count));
    fprintf(output,"{\"schema\":\"xtcp-payload/v1\",\"status\":\"%s\",\"mode\":",pass?"PASS":"FAIL");json_string(output,argv[1]);
    fprintf(output,",\"requested_bytes\":%" PRIu64 ",\"sent_bytes\":%" PRIu64 ",\"verified_received_bytes\":%" PRIu64 ",\"start_mono_ns\":%" PRIu64 ",\"data_end_mono_ns\":%" PRIu64 ",\"end_mono_ns\":%" PRIu64,c.count,sent,received,c.start_ns,data_end,end_ns);
    double seconds=(end_ns&&c.start_ns)?(end_ns-c.start_ns)/1e9:0;
    fprintf(output,",\"completion_seconds\":%.9f,\"data_seconds\":%.9f,\"cpu_user_seconds\":%.9f,\"cpu_system_seconds\":%.9f,\"rcvbuf_start\":%d,\"sndbuf_start\":%d,\"rcvbuf_final\":%d,\"sndbuf_final\":%d,\"requested_sockbuf\":%ld,\"mismatch_offset\":%" PRIu64 ",\"error\":",seconds,
        (data_end&&c.start_ns)?(data_end-c.start_ns)/1e9:0,tv_seconds(usage1.ru_utime)-tv_seconds(usage0.ru_utime),tv_seconds(usage1.ru_stime)-tv_seconds(usage0.ru_stime),rcv_start,snd_start,rcv_final,snd_final,sockbuf,c.mismatch_offset);
    json_string(output,c.error);fputs(",\"tcp_initial\":",output);info_json(output,&c.initial,c.initial_len);fputs(",\"tcp_final\":",output);info_json(output,&c.final,c.final_len);fputs("}\n",output);
    if(c.fd>=0){shutdown(c.fd,SHUT_RDWR);close(c.fd);}fclose(c.progress);fclose(output);free(c.pattern);
    printf("%s mode=%s sent=%" PRIu64 " verified=%" PRIu64 " seconds=%.6f\n",pass?"PASS":"FAIL",argv[1],sent,received,seconds);
    pthread_cond_destroy(&c.condition);pthread_mutex_destroy(&c.lock);return pass?0:1;
}
