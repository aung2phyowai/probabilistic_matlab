function [samples, log_Zs, b_accept, mus] = a_pgibbs(sampling_functions,weighting_functions,...
                              N,resample_method,n_iter,b_compress,f,b_Rao_Black,initial_retained_particle)
%a_pgibbs   Alternate move particle Gibbs 
%
% Carries out the alternate move particle Gibbs (APG) algorithm which
% interleaves PG and PIMH steps.  For more information see section 4 of the
% iPMCMC paper or Roman Holenstein's PhD thesis.
%
% Required inputs:
%   sampling_functions = See infer.m
%   weighting_functions = See infer.m
%   N (+ve integer) = Number of particles, also N in paper
%   resample_method = Method used in resampling.  See resample_particles.m.
%                     If empty takes default from resample_particles.m
%   n_iter (+ve integer) = Number of iterations
%   b_compress (boolean) = Whether to use compress_samples
%   f = Function to take expectation of.  Takes the var field of samples as
%       inputs.  See function_expectation.m.
%                               Default = []; (i.e. no estimate made)
%   b_Rao_Black (boolean) = Whether to Rao-Blackwellize and return all
%                           generated samples or just the retained particle
%
% Optional inputs:
%   initial_retained_particle (stack_object) = Allows the algorithm to be
%                          initialized with a retained particle.  If not
%                          provided, the first iteration runs as an
%                          unconditional sweep.
%
% Outputs:
%   samples = Object array of type stack_object containing details about
%             sampled variables, their weights and any constant variables
%   log_Zs = Marginal likelihood of individual sweeps
%   b_accept = Boolean vector indicating if that iteration is accepted
%   mus = Mean estimates of individual sweeps
%
% Tom Rainforth 08/06/16

if ~exist('f','var'); f = []; end
if ~exist('b_Rao_Black','var') || isempty(b_Rao_Black); b_Rao_Black = true; end

log_Zs = NaN(n_iter,1);
b_accept = true(n_iter,1);
b_compress = b_compress && b_Rao_Black;

if ~exist('initial_retained_particle','var')
    initial_retained_particle = [];
end
retained_particle = initial_retained_particle;

for iter=1:n_iter
    
    if mod(iter,2)==0
        % At even steps, carry out a PIMH transition.  This uses pg_sweep
        % rather than smc_sweep because of requiring the sampling of a new
        % retained particle at the end of the sweep
        [sample_proposed, log_Z_proposed, retained_particle_proposed, mu_proposed] ...
            = pg_sweep(sampling_functions,weighting_functions,N,[],resample_method,b_compress,f,b_Rao_Black);
        bKeep = rand<min(1,exp(log_Z_proposed-log_Zs(iter-1)));
        if bKeep
            samples(iter) = sample_proposed; %#ok<AGROW>
            log_Zs(iter) = log_Z_proposed;
            retained_particle = retained_particle_proposed;
            mus(iter,:) = mu_proposed;
        else
            samples(iter) = samples(iter-1); %#ok<AGROW>
            log_Zs(iter) = log_Zs(iter-1);
            b_accept(iter) = false;
            mus(iter,:) = mus(iter-1,:);
        end
    else
        % At the odd steps, carry out a PG step
        [samples(iter), log_Zs(iter), retained_particle, mus(iter,:)] ...
            = pg_sweep(sampling_functions,weighting_functions,N,retained_particle,resample_method,b_compress,f,b_Rao_Black); %#ok<AGROW>
    end
    
    if iter==1 && ~b_compress
        % Memory management once have information from the first iteration
        [samples,b_compress] = memory_check(samples,n_iter,numel(sampling_functions));
        samples = repmat(samples,n_iter,1);
    end
    
end


end