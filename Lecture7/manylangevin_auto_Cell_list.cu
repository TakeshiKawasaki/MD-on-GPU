#include <cuda.h>
#include <stdio.h>
#include <time.h>
#include "../timer.cuh"
#include <math.h>
#include <iostream>
#include <fstream>
#include <curand.h>
#include <curand_kernel.h>
#include "MT.h"
using namespace std;

//Using "const", the variable is shared into both gpu and cpu. 
const int  NT = 1024; //Num of the cuda threads.
const int  NP = 1e+5; //Particle number.
const int  NB = (NP+NT-1)/NT; //Num of the cuda blocks.
const int  NN = 100;
const int  NPC = 1000; // Number of the particles in the neighbour cell 
const double dt = 0.01;
const int timemax = 1e+2;
//Langevin parameters
const double zeta = 1.0;
const double temp = 1.e-4;
const double rho = 0.95;
const double RCHK= 1.5;
const double rcut= 1.0;


//Initiallization of "curandState"
__global__ void setCurand(unsigned long long seed, curandState *state){
  int i_global = threadIdx.x + blockIdx.x*blockDim.x;
  curand_init(seed, i_global, 0, &state[i_global]);
}

//Gaussian random number's generation
__global__ void genrand_kernel(float *result, curandState *state){  
  int i_global = threadIdx.x + blockIdx.x*blockDim.x;
  result[i_global] = curand_normal(&state[i_global]);
}

//Gaussian random number's generation
__global__ void langevin_kernel(double*x_dev,double*y_dev,double *vx_dev,double *vy_dev,double *fx_dev,double *fy_dev,curandState *state, double noise_intensity,double LB){
  int i_global = threadIdx.x + blockIdx.x*blockDim.x;

  if(i_global<NP){
    vx_dev[i_global] += -zeta*vx_dev[i_global]*dt+ fx_dev[i_global]*dt + noise_intensity*curand_normal(&state[i_global]);
    vy_dev[i_global] += -zeta*vy_dev[i_global]*dt+ fy_dev[i_global]*dt + noise_intensity*curand_normal(&state[i_global]);
    x_dev[i_global] += vx_dev[i_global]*dt;
    y_dev[i_global] += vy_dev[i_global]*dt;

    x_dev[i_global]  -= LB*floor(x_dev[i_global]/LB);
    y_dev[i_global]  -= LB*floor(y_dev[i_global]/LB);
  }
}



__global__ void disp_gate_kernel(double LB,double *vx_dev,double *vy_dev,double *dx_dev,double *dy_dev,int *gate_dev)
{
  double r2;  
  int i_global = threadIdx.x + blockIdx.x*blockDim.x;
  
  if(i_global<NP){
    dx_dev[i_global]+=vx_dev[i_global]*dt;
    dy_dev[i_global]+=vy_dev[i_global]*dt;
    r2 = dx_dev[i_global]*dx_dev[i_global]+dy_dev[i_global]*dy_dev[i_global];
    if(r2> 0.25*(RCHK-rcut)*(RCHK-rcut)){
      gate_dev[0]=1;
    }
  }
}


__global__ void update(double LB,double *x_dev,double *y_dev,double *dx_dev,double *dy_dev,int *list_dev,int *gate_dev)
{
  double dx,dy,r2;  
  int i_global = threadIdx.x + blockIdx.x*blockDim.x;
  
  if(gate_dev[0] == 1 && i_global<NP){
    
    list_dev[NN*i_global]=0;      
    for (int j=0; j<NP; j++)
      if(j != i_global){
	dx =x_dev[i_global] - x_dev[j];
	dy =y_dev[i_global] - y_dev[j];
	dx -=LB*floor(dx/LB+0.5);
	dy -=LB*floor(dy/LB+0.5);	  
	r2 = dx*dx + dy*dy;
	if(r2 < RCHK*RCHK){
	  list_dev[NN*i_global]++;
	  list_dev[NN*i_global+list_dev[NN*i_global]]=j;
	}
      }
    //    printf("i=%d, list=%d\n",i_global,list_dev[NN*i_global]);      
    dx_dev[i_global]=0.;
    dy_dev[i_global]=0.;
  }
}

__device__ int f(int i,int M){
  int k;
  k=i;
  if(k>=M)
    k-=M;
  if(k<0)
    k+=M;
  return k;
}



__global__ void cell_map(double LB,double *x_dev,double *y_dev,int *map_dev,int *gate_dev, int M)
{
  
  int i_global = threadIdx.x + blockIdx.x*blockDim.x;
  int nx,ny;
   int num;
  
  if(gate_dev[0] == 1 && i_global<NP){
    
    nx=f((int)(x_dev[i_global]*(double)M/(double)LB),M);
    ny=f((int)(y_dev[i_global]*(double)M/(double)LB),M);
    
    //  for(int m=ny-1;m<=ny+1;m++)
    //  for(int l=nx-1;l<=nx+1;l++){
    num = atomicAdd(&map_dev[(nx+M*ny)*NPC],1);
    // num = map_dev[(nx+M*ny)*NPC]+1;
    // if(num == 0)
    //  printf("%d = %d\n",num,map_dev[(nx+M*ny)*NPC]);
    map_dev[(nx+M*ny)*NPC+num+1] = i_global;
    
    //	if(num>70)
    //	printf("i=%d, map_dev=%d, f=%d, MM=%d, num=%d\n",i_global,map_dev[(f(l,M)+M*f(m,M))*NPC + num], f(l,M)+M*f(m,M),M*M,num);
    // }
    //  printf("i=%d\n",i_global);    
    // }
    //  printf("i=%d, map_dev=%d, f=%d, MM=%d, num=%d\n",i_global,map_dev[(f(l,M)+M*f(m,M))*NPC + num], f(l,M)+M*f(m,M),M*M,num);
  }
}
  
  
__global__ void cell_list(double LB,double *x_dev,double *y_dev,double *dx_dev,double *dy_dev,int *list_dev,int *map_dev,int *gate_dev, int M)
{
  int i_global = threadIdx.x + blockIdx.x*blockDim.x;
  int nx,ny;
  int j,k;
  double dx,dy,r2;  
  int l,m;
  //  printf("i=%d \n",i_global); 
  if(gate_dev[0] == 1 && i_global<NP){
    // if(i_global==0)
    // printf("update\n");
    list_dev[NN*i_global]=0;
    
    nx=f((int)(x_dev[i_global]*(double)M/(double)LB),M);
    ny=f((int)(y_dev[i_global]*(double)M/(double)LB),M);
    
    for(m=ny-1;m<=ny+1;m++)
      for(l=nx-1;l<=nx+1;l++){
	
	for(k=1; k<=map_dev[(f(l,M)+M*f(m,M))*NPC]; k++){
	  j = map_dev[(f(l,M)+M*f(m,M))*NPC+k];
	  if(j != i_global){
	    dx =x_dev[i_global] - x_dev[j];
	    dy =y_dev[i_global] - y_dev[j];
	    dx -=LB*floor(dx/LB+0.5);
	    dy -=LB*floor(dy/LB+0.5);	  
	    r2 = dx*dx + dy*dy;
	    if(r2 < RCHK*RCHK){
	      list_dev[NN*i_global]++;
	      list_dev[NN*i_global+list_dev[NN*i_global]]=j;
	      // printf("i=%d, list=%d\n",i_global,list_dev[NN*i_global]);     
	    }
	  }
	}
      }
    //    printf("i=%d, list=%d\n",i_global,list_dev[NN*i_global]);      
    dx_dev[i_global]=0.;
    dy_dev[i_global]=0.;
  } 
}


__global__ void calc_force_kernel(double*x_dev,double*y_dev,double *fx_dev,double *fy_dev,double *a_dev,double LB,int *list_dev){
  double dx,dy,dr,dU,a_i,fx_i,fy_i;
  int i_global = threadIdx.x + blockIdx.x*blockDim.x;
  a_i  = a_dev[i_global];
  fx_i = 0.0;
  fy_i = 0.0;
  
  if(i_global<NP){
    for(int j = 1; j<=list_dev[NN*i_global]; j++){
      dx=x_dev[list_dev[NN*i_global+j]]-x_dev[i_global];
      dy=y_dev[list_dev[NN*i_global+j]]-y_dev[i_global];
      
      dx -= LB*floor(dx/LB+0.5);
      dy -= LB*floor(dy/LB+0.5);	
      dr = sqrt(dx*dx+dy*dy);
      
      if(dr < 0.5*(a_i+a_dev[list_dev[NN*i_global+j]]))
	dU = -(1-dr/a_i)/a_i; //derivertive of U wrt r.
      
      else
	dU=0.0;  
      fx_i += dU*dx/dr;
      fy_i += dU*dy/dr;
    }
    fx_dev[i_global] = fx_i;
    fy_dev[i_global] = fy_i;
    // printf("i=%d, fx=%f\n",i_global,fx_dev[i_global]);
  }
}

__global__ void copy_kernel(double *x0_dev, double *y0_dev, double *x_dev, double *y_dev){
  int i_global = threadIdx.x + blockIdx.x*blockDim.x;
  x0_dev[i_global]=x_dev[i_global];
  y0_dev[i_global]=y_dev[i_global];
  // printf("%f,%f\n",x_dev[i_global],x0_dev[i_global]);
}

__global__ void init_gate_kernel(int *gate_dev, int c){
  gate_dev[0]=c;
}

__global__ void init_map_kernel(int *map_dev,int M){
  int i_global = threadIdx.x + blockIdx.x*blockDim.x;
  // for(int i=0;i<M;i++)
  //  for(int j=0;j<M;j++)
  // map_dev[(i+M*j)*NPC] = 0;
  map_dev[i_global] = 0;
}

__global__ void init_array(double *x_dev, double c){
  int i_global = threadIdx.x + blockIdx.x*blockDim.x;
  x_dev[i_global] = c;
}

__global__ void init_array_rand(double *x_dev, double c,curandState *state){
  int i_global = threadIdx.x + blockIdx.x*blockDim.x;
  x_dev[i_global] = c*curand_uniform(&state[i_global]);
}

void output(double *x,double *y,double *vx,double *vy,double *a){
  static int count=1;
  char filename[128];
  sprintf(filename,"coord_%.d.dat",count);
  ofstream file;
  file.open(filename);
  double temp0=0.0;
  
  for(int i=0;i<NP;i++){
    file << x[i] << " " << y[i]<< " " << a[i] << endl;
    temp0+= (vx[i]*vx[i]);
    // cout <<i<<" "<<map[i]<<endl;
  }

  file.close();

  cout<<"temp="<< temp0/NP <<endl;
  count++;
}


int main(){
  double *x,*vx,*y,*vy,*a,*x_dev,*vx_dev,*y_dev,*dx_dev,*dy_dev,*vy_dev,*a_dev,*fx_dev,*fy_dev;
  int *list_dev,*map_dev,*gate_dev;
  curandState *state; //Cuda state for random numbers
  double sec; //measurred time
  double noise_intensity = sqrt(2.*zeta*temp*dt); //Langevin noise intensity.   
  double LB = sqrt(M_PI*1.0*1.0*(double)NP*0.25/rho);
  int M = (int)(LB/RCHK);
  cout <<M<<endl;

  x  = (double*)malloc(NB*NT*sizeof(double));
  y  = (double*)malloc(NB*NT*sizeof(double));
  vx = (double*)malloc(NB*NT*sizeof(double));
  vy = (double*)malloc(NB*NT*sizeof(double));
  a  = (double*)malloc(NB*NT*sizeof(double));
  // map  = (int*)malloc(M*M*NPC*sizeof(int));
  cudaMalloc((void**)&x_dev,  NB * NT * sizeof(double)); // CudaMalloc should be executed once in the host. 
  cudaMalloc((void**)&y_dev,  NB * NT * sizeof(double)); 
  cudaMalloc((void**)&dx_dev,  NB * NT * sizeof(double)); 
  cudaMalloc((void**)&dy_dev,  NB * NT * sizeof(double)); 
  cudaMalloc((void**)&vx_dev, NB * NT * sizeof(double)); 
  cudaMalloc((void**)&vy_dev, NB * NT * sizeof(double));
  cudaMalloc((void**)&fx_dev, NB * NT * sizeof(double)); 
  cudaMalloc((void**)&fy_dev, NB * NT * sizeof(double));
  cudaMalloc((void**)&a_dev,  NB * NT * sizeof(double)); 
  cudaMalloc((void**)&gate_dev, sizeof(int)); 
  cudaMalloc((void**)&list_dev,  NB * NT * NN* sizeof(int)); 
  cudaMalloc((void**)&map_dev,  M * M * NPC* sizeof(int)); 
  cudaMalloc((void**)&state,  NB * NT * sizeof(curandState)); 

  setCurand<<<NB,NT>>>(0, state); // Construction of the cudarand state.  

  init_array_rand<<<NB,NT>>>(x_dev,LB,state);
  init_array_rand<<<NB,NT>>>(y_dev,LB,state);
  init_array<<<NB,NT>>>(a_dev,1.0);
  init_array<<<NB,NT>>>(vx_dev,0.);
  init_array<<<NB,NT>>>(vy_dev,0.);
  
  init_gate_kernel<<<1,1>>>(gate_dev,1);
  init_map_kernel<<<M*M,NPC>>>(map_dev,M);
  cell_map<<<NB,NT>>>(LB,x_dev,y_dev,map_dev,gate_dev,M);
  // cudaMemcpy(map,map_dev, M * M * NPC* sizeof(int),cudaMemcpyDeviceToHost);
  cell_list<<<NB,NT>>>(LB,x_dev,y_dev,dx_dev,dy_dev,list_dev,map_dev,gate_dev,M);
  // cudaDeviceSynchronize(); 
  //  update<<<NB,NT>>>(LB,x_dev,y_dev,dx_dev,dy_dev,list_dev,gate_dev);

  measureTime(); 
  for(double t=0;t<timemax;t+=dt){
    // cout<<t<<endl;
    calc_force_kernel<<<NB,NT>>>(x_dev,y_dev,fx_dev,fy_dev,a_dev,LB,list_dev);
    langevin_kernel<<<NB,NT>>>(x_dev,y_dev,vx_dev,vy_dev,fx_dev,fy_dev,state,noise_intensity,LB);
    init_gate_kernel<<<1,1>>>(gate_dev,0);
    disp_gate_kernel<<<NB,NT>>>(LB,vx_dev,vy_dev,dx_dev,dy_dev,gate_dev);
    init_map_kernel<<<M*M,NPC>>>(map_dev,M);
    // cudaDeviceSynchronize(); // for printf in the device.
    cell_map<<<NB,NT>>>(LB,x_dev,y_dev,map_dev,gate_dev,M);
    cell_list<<<NB,NT>>>(LB,x_dev,y_dev,dx_dev,dy_dev,list_dev,map_dev,gate_dev,M);
  } 
  sec = measureTime()/1000.;
  cout<<"time(sec):"<<sec<<endl;
 

  cudaMemcpy(x,   x_dev, NB * NT* sizeof(double),cudaMemcpyDeviceToHost);
  cudaMemcpy(vx, vx_dev, NB * NT* sizeof(double),cudaMemcpyDeviceToHost);
  cudaMemcpy(y,   y_dev, NB * NT* sizeof(double),cudaMemcpyDeviceToHost);
  cudaMemcpy(vy, vy_dev, NB * NT* sizeof(double),cudaMemcpyDeviceToHost);
  cudaMemcpy(a, a_dev, NB * NT* sizeof(double),cudaMemcpyDeviceToHost);
  
  output(x,y,vx,vy,a);
 

  cudaFree(x_dev);
  cudaFree(vx_dev);
  cudaFree(y_dev);
  cudaFree(vy_dev);
  cudaFree(dx_dev);
  cudaFree(dy_dev);
  cudaFree(gate_dev);
  cudaFree(state);
  free(x); 
  free(vx); 
  free(y); 
  free(vy); 
  return 0;
}
