#!python
#cython: boundscheck=False, wraparound=False
# -*- coding: utf-8 -*-
"""
Created on Sat Dec 16 17:52:52 2017

@author: paulo.hubert@gmail.com

Automatic signal segmentation
"""

import sys
sys.path.append('./Software/CythonGSL/CythonGSL-0.2.1/cython_gsl')

import time

import numpy as np
cimport numpy as np
import operator
import re

cimport cython
from cython_gsl cimport *
from cython_gsl import *
from cython.parallel cimport prange, parallel
from cython.parallel import prange, parallel

# Type for Cython NumPy acceleration
DTYPE = np.float64
ctypedef np.float64_t DTYPE_t

# External functions from math.h
cdef extern from "math.h" nogil:
    double lgamma(double)

cdef double gammaln(double x) nogil:
    return lgamma(x)

cdef extern from "math.h" nogil:
    double log(double)

cdef double Ln(double x) nogil:
    return log(x)

cdef double Abs(double x) nogil:
    if x < 0:
        return -x
    else:
        return x

cdef extern from "math.h" nogil:
    double sqrt(double)

cdef double Sqrt(double x) nogil:
    return sqrt(x)

# Random number generator - Mersenne Twister
cdef gsl_rng *r = gsl_rng_alloc(gsl_rng_mt19937)


# Cython pure C functions
cdef double cposterior_t(long t, long tstart, long tend, double prior_v, double send, double sstart, double st, double st1) nogil:
    ''' Calculates the log-posterior distribution for t

        Args:

        t - segmentation point
        tstart - start index of current signal window
        tend - end indef of current signal window
        prior_v - prior value associated to t
        send - sum of amplitude squared from 0 to tend
        sstart - sum of amplitude squared from 0 t0 tstart
        st - sum of amplitude squared from 0 to t
        st1 - sum of amplitude squared from t+1 to tend
    '''

    cdef long adjt = t - tstart + 1
    cdef long Nw = tend - tstart + 1
    cdef double dif1 = st-sstart
    cdef double dif2 = send - st1
    cdef double arg1 = 0.5*(adjt + 6)
    cdef double arg2 = 0.5*(Nw - adjt - 6)
    cdef double arg3 = 0.5*(Nw - adjt - 2)
    cdef double post = prior_v - arg1*(Ln(dif1)) - arg2*(Ln(dif2)) + gammaln(arg1) + gammaln(arg3)

    return post


cdef double cposterior_full(double d, double s, long Nw, long N2, double beta, double sum1, double sum2) nogil:
    ''' Full log-posterior kernel for MCMC sampling

        Arguments:

        d - current value for delta
        s - current value for sigma
        Nw - total signal size
        N2 - size of second segment
        beta - parameter for laplace prior
        sum1 - sum of amplitudes squared for first segment
        sum2 - sum of amplitudes squared for second segment
    '''
    
    if d <= 0 or s <= 0:
        return -1e+308
    # Jeffreys' prior for sigma
    cdef double dpriors = -Ln(s)

    # Laplace prior for delta
    cdef double dpriord = -Ln(beta) - Abs(d-1)/beta

    cdef double post = dpriord +  dpriors - Nw*Ln(s)-0.5*N2*Ln(d)
    post = post - sum1/(2*(s**2)) - sum2/(2*d*(s**2))

    return post


cdef double cmcmc(int mcburn, int mciter, double p0, double beta, long N, long N2, double sum1, double sum2) nogil:
    ''' Run MCMC

        Arguments:

        mcburn - burn-in period for chain
        mciter - number of points to sample
        p0 - posterior under H0
        beta - parameter for Laplace prior
        N - total signal size
        N2 - size of second segment
        sum1 - sum of amplitude squared for the first segment
        sum2 - sum of amplitude squared for the second segment

    '''
    cdef double pcur, pcand, scur, scand, dcur, dcand, a, u, ev
    cdef int i, t0, t
    cdef double dvar, svar, cov, sd, eps, u1, u2, dmean, dmeanant, smean, smeanant, cov0, sumdsq, sumssq
    cdef double accept, dvarmin, svarmin

    dcur = (sum2 / (N2-1))/(sum1 / (N-N2-1))
    scur = Sqrt(sum1 / (N-N2-1))

    # Standard deviations and covariance for random-walk candidates distributions
    dvar = (dcur / 3) ** 2
    svar = (scur / 3) ** 2
    cov = 0.0
    
    # To safeguard variances    
    dvarmin = dvar
    svarmin = svar    
    
    
    # Generating starting values for the chain
    dcur = Abs(dcur + gsl_ran_gaussian(r, Sqrt(dvar)))
    scur = Abs(scur + gsl_ran_gaussian(r, Sqrt(svar)))
    pcur = cposterior_full(dcur, scur, N, N2, beta, sum1, sum2)
    
    # Parameters for adaptive MH
    sd = (2.4*2.4)/2.0
    eps = 1e-30

    # Starting point for adaptive MH
    t0 = 1000
    
    dmean = 0.0
    smean = 0.0
    sumdsq = 0.0
    sumssq = 0.0
    cov0 = 0.0
    accept = 0
    for i in range(t0):
        
        # Generate candidates
        u1 = gsl_ran_ugaussian(r)
        dcand = dcur + u1*Sqrt(dvar)
        
        # Calculates full posterior
        pcand = cposterior_full(dcand, scur, N, N2, beta, sum1, sum2)

        # Acceptance ratio
        a = pcand - pcur

        if Ln(gsl_rng_uniform(r)) < a:
            dcur = dcand
            pcur = pcand
            accept = accept + 1
        #endif
        
        u2 = gsl_ran_ugaussian(r)
        scand = scur + Sqrt(svar)*u2

        # Calculates full posterior
        pcand = cposterior_full(dcur, scand, N, N2, beta, sum1, sum2)

        # Acceptance ratio
        a = pcand - pcur

        if Ln(gsl_rng_uniform(r)) < a:
            scur = scand
            pcur = pcand
            accept = accept + 1
        #endif
            
        dmean = dmean + dcur
        smean = smean + scur
        cov0 = cov0 + dcur*scur
        sumdsq = sumdsq + dcur*dcur
        sumssq = sumssq + scur*scur
        
    #endfor
       
    dvar = (sumdsq - (dmean*dmean)/t0)/(t0-1)
    svar = (sumssq - (smean*smean)/t0)/(t0-1)


    if svar < 0:
        with gil:
            print("Posterior variance of signal power with negative value!")
        svar = svarmin
        
    if dvar < 0:
        with gil:
            print("Posterior variance of delta with negative value!")
        dvar = dvarmin
        
    cov = (1/(t0-1))*(cov0 - dmean*smean/t0)
    rho = cov/Sqrt(dvar*svar)
    dmean = dmean / t0
    smean = smean / t0    
    t = t0
    
    accept = 0
    for i in range(mcburn):

        # Generate candidates
        u1 = gsl_ran_ugaussian(r)
        u2 = gsl_ran_ugaussian(r)
        if Abs(rho) > 1:
            with gil:
                print("Adaptive covariance defective!")
            rho = 0
        u2 = rho*u1 + (1-rho)*u2
        
        
        dcand = dcur + u1*Sqrt(dvar)
        scand = scur + u2*Sqrt(svar)

        if dcand > 0 and scand > 0:        
            # Calculates full posterior
            pcand = cposterior_full(dcand, scand, N, N2, beta, sum1, sum2)
    
            # Acceptance ratio
            a = pcand - pcur
    
            if Ln(gsl_rng_uniform(r)) < a:
                scur = scand
                dcur = dcand
                pcur = pcand
                accept = accept + 1
            #endif
        #endif     
                
        # Updating covariance matrix
        dmeanant = dmean
        smeanant = smean
        dmean = (t*dmeanant + dcur) / (t + 1)
        smean = (t*smeanant + scur) / (t + 1)

        dvar =  (((t-1)*dvar)/t) + (sd/t)*(t*dmeanant*dmeanant - (t+1)*dmean*dmean + dcur*dcur + eps)
        svar =  (((t-1)*svar)/t) + (sd/t)*(t*smeanant*smeanant - (t+1)*smean*smean + scur*scur + eps)
        cov = (((t-1)*cov)/t) + (sd/t)*(t*dmeanant*smeanant - (t+1)*dmean*smean + dcur*scur)
        rho = cov/Sqrt(dvar*svar)
        t = t + 1            
    #endfor

    ev = 0.0
    dtmp = 0.0
    stmp = 0.0
    accept = 0
    for i in range(mciter):
        # Generate candidates
        u1 = gsl_ran_ugaussian(r)
        u2 = gsl_ran_ugaussian(r)
        u2 = rho*u1 + (1-rho)*u2
        
        dcand = dcur + u1*Sqrt(dvar)
        scand = scur + u2*Sqrt(svar)

        if dcand > 0 and scand > 0:
            # Calculates full posterior
            pcand = cposterior_full(dcand, scand, N, N2, beta, sum1, sum2)
            
            # Acceptance ratio
            a = pcand - pcur
    
            if Ln(gsl_rng_uniform(r)) < a:
                dcur = dcand
                scur = scand
                pcur = pcand
                accept = accept + 1
            #endif
        #endif

        if pcur > p0:
            ev = ev + 1.0
        #endif            
    #endfor

    
    ev = ev / mciter

    return ev


# Interface
cdef class SeqSeg:
    ''' class SeqSeg: implements the python interface for the sequential segmentation algorithm

        Hubert, P., Padovese, L., Stern, J. A sequential algorithm for signal segmentation, Entropy 20 (1) 55 (2018)
        
        Hubert, P., Padovese, L., Stern, J. Fast parallel implementation and calibration method for
                an unsupervised Bayesian segmentation algorithm, submitted for publication
        
        Please cite these papers if you use the algorithm
    '''

    cdef long N, tstart, tend
    cdef int mciter, mcburn, nchains, minlen, tstep
    cdef double beta, alpha
    cdef np.ndarray wave, sumw2
    cdef bint data_fed, initialized


    def __init__(self, np.ndarray wave = None):

        self.wave = wave
        if wave is None:
            self.data_fed = False
        else:
            self.data_fed = True
        
        self.initialized = False

        self.initialize()

        np.seterr(over = 'ignore', under = 'ignore')



    def initialize(self, double beta = 2.9e-5, double alpha = 0.1, int mciter = 4000, int mcburn = 1000, int nchains = 1):
        ''' Initializes the segmenter

            Can be called explicitly to set parameters for the MCMC
        '''

        if self.wave is not None:
            
            self.sumw2 = np.cumsum(self.wave**2)
            self.sumw2 = np.insert(self.sumw2, 0, 0)
            self.N = len(self.wave)
            
            # Current segment start and end
            self.tstart = 0
            self.tend = self.N-1
            
        else:
            
            self.tstart = 0
            self.tend = 0
            self.sumw2 = None
            self.N = -1


        self.mciter = mciter
        self.mcburn = mcburn
        self.nchains = nchains

        self.beta = beta
        self.alpha = alpha

        self.initialized = True


    def feed_data(self, wave):
        ''' Stores the signal and updates internal variables
        '''
        
        self.wave = wave
        self.N = len(wave)
        self.sumw2 = np.cumsum(self.wave**2)
        self.sumw2 = np.insert(self.sumw2, 0, 0)
        
        # Current segment start and end
        self.tstart = 0
        self.tend = self.N-1

        self.data_fed = True


    cpdef double tester(self, long tcut, bint normalize = False):
        ''' Tests if tcut is a significant cutpoint
            Can be called separately to test the current segment.
        '''
        cdef double s0, p0, ev, sum1, sum2, beta
        cdef long n, N, N2
        cdef int i, nburn, npoints
        cdef np.ndarray[DTYPE_t, ndim = 1] vev = np.repeat(0.0, self.nchains)

        # Calculating sum of squares of amplitudes for both segments
        sum1 = self.sumw2[tcut] - self.sumw2[self.tstart]
        sum2 = self.sumw2[self.tend] - self.sumw2[tcut]
        
        if normalize:
            sum2 = sum2 / sum1
            sum1 = 1.0

        N = self.N
        N2 = self.tend - tcut
        nburn = self.mcburn
        npoints = self.mciter
        beta = self.beta

        # Calculates maximum posterior under H0
        s0 = Sqrt((sum1 + sum2)/(N + 1.))
        p0 = cposterior_full(1.0, s0, N, N2, beta, sum1, sum2)

        # Run chains
        with nogil, parallel():
            for i in prange(self.nchains, schedule = 'static'):
                vev[i] = cmcmc(nburn, npoints, p0, beta, N, N2, sum1, sum2)

        # Evidence IN FAVOR OF null hypothesis (delta = 1)        
        ev = 1 - sum(vev) / self.nchains

        return ev

    def get_posterior(self, start, end, res = 1):


        if not self.data_fed:

            print("Data not initialized! Call feed_data.")
            return(-1)   

        cdef long t, n, istart, iend, tstep, tstart, tend
        cdef double sstart, send, st, st1
        cdef np.ndarray[DTYPE_t, ndim = 1] tvec = np.repeat(-np.inf, self.N)
        cdef np.ndarray[DTYPE_t, ndim = 1] esumw2 = self.sumw2

        self.N = len(self.wave)

        if end > self.N:
            print("Invalid value for tend.")
            return([], -1)
				
        if start < 0:
            print("Invalid value for start.")
            return([], -1)

        tstep = res
        
        # Sets start and end
        tstart = start
        tend = end

        # Obtains MAP estimate of the cut point
        # Parallelized

        # Bounds for start and end
        istart = tstart + 3
        iend = tend - 3
        n = int((iend-istart)/tstep)

        sstart = self.sumw2[self.tstart]
        send = self.sumw2[self.tend]

        tvec = np.repeat(-np.inf, n + 1)
        with nogil, parallel():
            for t in prange(n + 1, schedule = 'static'):
                st = esumw2[istart + t*tstep]
                st1 = esumw2[istart + t*tstep + 1]
                tvec[t] = cposterior_t(istart + t*tstep, tstart, tend, 0, send, sstart, st, st1)


        end = time.time()
        elapsed = end - begin
        
        return tvec, elapsed





    def segments(self, minlen = 1, res = 1, normalize = False, verbose = False):
        ''' Applies the sequential segmentation algorithm to the wave,
            returns the vector with segments' index
        '''

        if not self.data_fed:

            print("Data not initialized! Call feed_data.")
            return(-1)        
        
        begin = time.time()

        # Cannot have a minimum segment of less than 5 points for the algorithm to make sense
        minlen = max(5, minlen)
        
        cdef long t, tmax, tstart, tend, n, istart, iend, tstep
        cdef double maxp, posterior, sstart, send, st, st1
        cdef np.ndarray[DTYPE_t, ndim = 1] tvec = np.repeat(-np.inf, self.N)
        cdef np.ndarray[DTYPE_t, ndim = 1] esumw2 = self.sumw2



        self.tstart = 0
        self.tend = len(self.wave) - 1
        self.N = len(self.wave)

        tstep = res

        tseg = []
        # Creates index to keep track of tested segments
        # True, if the segment must be tested, False otherwise
        iseg = {str(self.tstart) + "-" + str(self.tend) : True}

        # Main loop: while there are untested segments
        while sum(iseg.values()) > 0:
            # Iterates through segments to be tested
            isegold = [i for i in iseg if iseg[i] == True]
            for seg in isegold:
                # Sets start and end
                times = re.match('(\d+)-(\d+)', seg)
                self.tstart = int(times.group(1))
                self.tend = int(times.group(2))
                self.N = self.tend - self.tstart + 1

                # Obtains MAP estimate of the cut point
                # Parallelized
                tstart = self.tstart
                tend = self.tend

                # Bounds for start and end
                istart = tstart + 3
                iend = tend - 3
                n = int((iend-istart)/tstep)

                sstart = self.sumw2[self.tstart]
                send = self.sumw2[self.tend]

                tvec = np.repeat(-np.inf, n + 1)
                with nogil, parallel():
                    for t in prange(n + 1, schedule = 'static'):
                        st = esumw2[istart + t*tstep]
                        st1 = esumw2[istart + t*tstep + 1]
                        tvec[t] = cposterior_t(istart + t*tstep, tstart, tend, 0, send, sstart, st, st1)

                tmax, maxp = max(enumerate(tvec), key=operator.itemgetter(1))

                # tmax is the optimum position in range(tstart+2, tend-3)
                # but WITH STEP SIZE = TSTEP
                tmax = istart + tmax*tstep

                if tmax - tstart > minlen and tend - tmax > minlen:
                    # Test the segments
                    evidence = self.tester(tmax, normalize)

                    if evidence < self.alpha:
                        if verbose:
                            print("Tcut = " + str(tmax) + ", start = " + str(self.tstart) + ", tend = " + str(self.tend) + ", N = " + str(self.N) + ", accepted: evidence = " + str(evidence))
                        #endif
                            
                        # Different variances
                        # Update list of segments
                        tseg.append(tmax)

                        # Update dict
                        iseg[str(tstart) + "-" + str(tmax)] = True
                        iseg[str(tmax + 1) + "-" + str(self.tend)] = True
                        del iseg[seg]

                    else:
                        
                        iseg[seg] = False
                        if verbose:
                            print("Tcut = " + str(tmax) + ", start = " + str(self.tstart) + ", tend = " + str(self.tend) + ", N = " + str(self.N) + ", rejected: evidence = " + str(evidence))
                        #endif
                    #endif

                else:
                    # Segment has been tested, no significant cut point found
                    iseg[seg] = False
                #endif
            #end for
        #endwhile
        end = time.time()
        elapsed = end - begin
        if verbose:
            print("End of execution: " + str(len(tseg) + 1) + " segments found in " + str(elapsed) + " seconds.")
        #endif
            
        return tseg, elapsed
