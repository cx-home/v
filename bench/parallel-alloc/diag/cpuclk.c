#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <stdint.h>
static uint64_t c(clockid_t id){struct timespec ts; clock_gettime(id,&ts); return (uint64_t)ts.tv_sec*1000000000ull+ts.tv_nsec;}
int main(void){
  for(int k=0;k<3;k++){
    uint64_t c0=c(CLOCK_THREAD_CPUTIME_ID), w0=c(CLOCK_MONOTONIC);
    usleep(200000);
    uint64_t c1=c(CLOCK_THREAD_CPUTIME_ID), w1=c(CLOCK_MONOTONIC);
    volatile uint64_t x=1; for(long i=0;i<200000000;i++) x=x*6364136223846793005ull+1;
    uint64_t c2=c(CLOCK_THREAD_CPUTIME_ID), w2=c(CLOCK_MONOTONIC);
    printf("cpuclk: usleep200ms cpu=%llu us wall=%llu us | spin cpu=%llu us wall=%llu us\n",
      (unsigned long long)(c1-c0)/1000,(unsigned long long)(w1-w0)/1000,(unsigned long long)(c2-c1)/1000,(unsigned long long)(w2-w1)/1000);
  }
  return 0;
}
