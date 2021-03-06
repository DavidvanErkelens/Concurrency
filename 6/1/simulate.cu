/*
 * simulate.cu
 *
 */


#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <iostream>

#include "file.h"
#include "timer.h"
#include "simulate.h"
#include "simulate.h"

using namespace std;

#define MAX_BLOCK_SIZE 1024

/* Utility function, use to do error checking.

   Use this function like this:

   checkCudaCall(cudaMalloc((void **) &deviceRGB, imgS * sizeof(color_t)));

   And to check the result of a kernel invocation:

   checkCudaCall(cudaGetLastError());
*/
static void checkCudaCall(cudaError_t result) {
    if (result != cudaSuccess) {
        printf("cuda error: %s\n", cudaGetErrorString(result));
        exit(1);
    }
}

__global__ void calculate_next(double *dev_old, double *dev_cur,
        double *dev_new, int i_max, int timestep) {

    unsigned int i = blockIdx.x * blockDim.x + threadIdx.x + 1;
    unsigned int t_id = threadIdx.x;

    if (i >= i_max) {
        return;
    }


    __shared__ double s_cur[MAX_BLOCK_SIZE];


    s_cur[t_id] = dev_cur[i];

    __syncthreads();


    if (t_id == 0) {
        dev_new[i] = 2 * s_cur[t_id] - dev_old[i] + 0.2 * (dev_cur[i - 1] -
                (2 * s_cur[t_id] - s_cur[t_id + 1]));
    }
    else if (t_id == blockDim.x - 1) {
        dev_new[i] = 2 * s_cur[t_id] - dev_old[i] + 0.2 * (s_cur[t_id - 1] -
                (2 * s_cur[t_id] - dev_cur[i + 1]));
    }
    else {
        dev_new[i] = 2 * s_cur[t_id] - dev_old[i] + 0.2 * (s_cur[t_id - 1] -
                (2 * s_cur[t_id] - s_cur[t_id + 1]));
    }

}

/*
 * Executes the entire simulation.
 *
 * Implement your code here.
 *
 * i_max: how many data points are on a single wave
 * t_max: how many iterations the simulation should run
 * block_size: how many threads to use (excluding the main threads)
 * old_array: array of size i_max filled with data for t-1
 * current_array: array of size i_max filled with data for t
 * next_array: array of size i_max. You should fill this with t+1
 */
double *simulate(const int i_max, const int t_max, const int block_size,
        double *old_array, double *current_array, double *next_array)
{
    double *dev_old, *dev_cur, *dev_new;

    // allocate the vectors on the GPU
    checkCudaCall(cudaMalloc(&dev_old, i_max * sizeof(double)));
    checkCudaCall(cudaMalloc(&dev_cur, i_max * sizeof(double)));
    checkCudaCall(cudaMalloc(&dev_new, i_max * sizeof(double)));


    // add events to calculate the time
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    // copy data to the vectors
    checkCudaCall(cudaMemcpy(dev_old, old_array, i_max * sizeof(double),
            cudaMemcpyHostToDevice));
    checkCudaCall(cudaMemcpy(dev_cur, current_array, i_max * sizeof(double),
            cudaMemcpyHostToDevice));
    checkCudaCall(cudaMemcpy(dev_new, next_array, i_max * sizeof(double),
            cudaMemcpyHostToDevice));



    cudaEventRecord(start, 0);


    for (int t = 1; t < t_max; t++) {
        // execute kernel
        calculate_next<<<ceil((double)i_max/block_size), block_size>>>(
                dev_old, dev_cur, dev_new, i_max - 1, t);



        // switch pointers over
        double *temp = dev_old;
        dev_old = dev_cur;
        dev_cur = dev_new;
        dev_new = temp;
    }


    cudaEventRecord(stop, 0);


    // check whether the kernel invocation was successful
    checkCudaCall(cudaGetLastError());


    // copy results back
    checkCudaCall(cudaMemcpy(current_array, dev_cur, i_max * sizeof(double),
            cudaMemcpyDeviceToHost));


    checkCudaCall(cudaFree(dev_old));
    checkCudaCall(cudaFree(dev_cur));
    checkCudaCall(cudaFree(dev_new));


    /* You should return a pointer to the array with the final results. */

    float elapsedTime;
    cudaEventElapsedTime(&elapsedTime, start, stop);

    printf("time spent in kernel: %f miliseconds\n", elapsedTime);


    return current_array;
}



typedef double (*func_t)(double x);

/*
 * Simple gauss with mu=0, sigma^1=1
 */
double gauss(double x)
{
    return exp((-1 * x * x) / 2);
}


/*
 * Fills a given array with samples of a given function. This is used to fill
 * the initial arrays with some starting data, to run the simulation on.
 *
 * The first sample is placed at array index `offset'. `range' samples are
 * taken, so your array should be able to store at least offset+range doubles.
 * The function `f' is sampled `range' times between `sample_start' and
 * `sample_end'.
 */
void fill(double *array, int offset, int range, double sample_start,
        double sample_end, func_t f)
{
    int i;
    float dx;

    dx = (sample_end - sample_start) / range;
    for (i = 0; i < range; i++) {
        array[i + offset] = f(sample_start + i * dx);
    }
}


int main(int argc, char *argv[])
{
    double *old, *current, *next;
    int t_max, i_max, block_size;
    timer waveform_timer("waveform timer");

    /* Parse commandline args: i_max t_max block_size */
    if (argc < 4) {
        printf("Usage: %s i_max t_max block_size [initial_data]\n", argv[0]);
        printf(" - i_max: number of discrete amplitude points, should be >2\n");
        printf(" - t_max: number of discrete timesteps, should be >=1\n");
        printf(" - block_size: number of threads to use for simulation, "
                "should be >=1\n");
        printf(" - initial_data: select what data should be used for the first "
                "two generation.\n");
        printf("   Available options are:\n");
        printf("    * sin: one period of the sinus function at the start.\n");
        printf("    * sinfull: entire data is filled with the sinus.\n");
        printf("    * gauss: a single gauss-function at the start.\n");
        printf("    * file <2 filenames>: allows you to specify a file with on "
                "each line a float for both generations.\n");

        return EXIT_FAILURE;
    }


    i_max = atoi(argv[1]);
    t_max = atoi(argv[2]);
    block_size = atoi(argv[3]);

    if (i_max < 3) {
        printf("argument error: i_max should be >2.\n");
        return EXIT_FAILURE;
    }
    if (t_max < 1) {
        printf("argument error: t_max should be >=1.\n");
        return EXIT_FAILURE;
    }
    if (block_size < 1) {
        printf("argument error: block_size should be >=1.\n");
        return EXIT_FAILURE;
    }


    /* Allocate and initialize buffers. */
    old = (double *) malloc(i_max * sizeof(double));
    current = (double *) malloc(i_max * sizeof(double));
    next = (double *) malloc(i_max * sizeof(double));


    if (old == NULL || current == NULL || next == NULL) {
        fprintf(stderr, "Could not allocate enough memory, aborting.\n");
        return EXIT_FAILURE;
    }

    memset(old, 0, i_max * sizeof(double));
    memset(current, 0, i_max * sizeof(double));
    memset(next, 0, i_max * sizeof(double));


    /* How should we will our first two generations? */
    if (argc > 4) {
        if (strcmp(argv[4], "sin") == 0) {
            fill(old, 1, i_max/4, 0, 2*3.14, sin);
            fill(current, 2, i_max/4, 0, 2*3.14, sin);
        } else if (strcmp(argv[4], "sinfull") == 0) {
            fill(old, 1, i_max-2, 0, 10*3.14, sin);
            fill(current, 2, i_max-3, 0, 10*3.14, sin);
        } else if (strcmp(argv[4], "gauss") == 0) {
            fill(old, 1, i_max/4, -3, 3, gauss);
            fill(current, 2, i_max/4, -3, 3, gauss);
        } else if (strcmp(argv[4], "file") == 0) {
            if (argc < 7) {
                printf("No files specified!\n");
                return EXIT_FAILURE;
            }
            file_read_double_array(argv[5], old, i_max);
            file_read_double_array(argv[6], current, i_max);
        } else {
            printf("Unknown initial mode: %s.\n", argv[4]);
            return EXIT_FAILURE;
        }
    } else {
        /* Default to sinus. */
        fill(old, 1, i_max/4, 0, 2*3.14, sin);
        fill(current, 2, i_max/4, 0, 2*3.14, sin);
    }


    waveform_timer.start();

    /* Call the actual simulation that should be implemented in simulate.c. */
    simulate(i_max, t_max, block_size, old, current, next);

    waveform_timer.stop();


    cout << waveform_timer;

    //printf("second timer: %f\n", vectorAddTimer);

    file_write_double_array("result.txt", current, i_max);

    free(old);
    free(current);
    free(next);

    return EXIT_SUCCESS;
}

