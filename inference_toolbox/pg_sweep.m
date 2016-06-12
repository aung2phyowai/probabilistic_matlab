function [particles, log_Z, retained_particle] = pg_sweep(sampling_functions,...
                weighting_functions,N,retained_particle,b_compress,b_Rao_Black)
%pg_sweep   Sweep used for Particle Gibbs and iPMCMC
%
% When provided with a retained particle, performs a conditional sequential
% Monte Carlo (CSMC) sweep as per Algorithm 2 in the paper.  Otherwise
% Performs sequential Monte Carlo (SMC) as per Algorithm 1 in the paper.
%
% Required inputs:
%   sampling_functions = See infer.m
%   weighting_functions = See infer.m
%   N (+ve integer) = Number of particles, also N in paper
%
% Optional inputs:
%   retained_particle = A retained particle of type stack_object.  Sweep
%                       will be conditioned on this particle when provided.
%                               Default = empty
%   b_compress (boolean) = Whether to use compress_samples
%                               Default = false;
%   b_Rao_Black (boolean) = If true all particles are returned with
%                           weights, else only a single particle (i.e. the
%                           retained particle) is returned
%                               Default = true;
%
% Outputs:
%   particles = Object of type stack_object storing all the samples.
%   log_Z = Log marginal likelihood estimate as per equation 4 in the paper
%   retained_particle = Particle sampled as the retained particle as per
%                       equation 7 (sampled in proportion to weight)
%
% Tom Rainforth 07/06/16

global sample_size

if ~exist('retained_particle','var') || isempty(retained_particle)
    % Run as an unconditional smc sweep if no retained particle supplied
    [particles, log_Z, variables_step, sizes_step] = smc_sweep(sampling_functions,weighting_functions,N,false,false);
else
    % Otherwise run as a conditional smc sweep.
    
    % Global variable that can be used as a controller inside the code for
    % sampling_functions and weighting functions if desired    
    sample_size = N-1; %#ok<NASGU>    
    particles = stack_object;
    log_Z = 0;
    [variables_step,sizes_step] = deal(cell(numel(sampling_functions),1));
        
    for n=1:numel(sampling_functions)
        % Sample from eq 1a in the paper
        particles = sampling_functions{n}(particles);
        
        % Store the variables at this step and the sizes for allowing later
        % reconstruction of the intermediary retained particles from the
        % final retained particle.
        variables_step{n} = fields(particles.var);
        for v=1:numel(variables_step{n})
            if isnumeric(particles.var.(variables_step{n}{v})) || (size(particles.var.(variables_step{n}{v}),2)>1)
                % Here we have an array so just need to store the second
                % dimension which is constant for all samples
                sizes_step{n}{v} = size(particles.var.(variables_step{n}{v}),2);
            elseif iscell(particles.var.(variables_step{n}{v}))
                % Here we have a n_samplesx1 size cell array so the size
                % might be different within each cell and needs storing
                % seperately
                sizes_step{n}{v} = cellfun(@(x) size(x,2), particles.var.(variables_step{n}{v}));
            else
                sizes_step{n}{v} = 1;
            end
        end
        
        % It is more memory efficient to recalculate the weight of the
        % retained particle then to store it when selecting it (as this
        % requires the full history of intermediary weights to be stored).
        % This requires reconstruction of the retained_particle at the
        % respective point in the state sequence.        
        intermediary_retained_particle = stack_object;
        intermediary_retained_particle.con = particles.con;
        for v=1:numel(retained_particle.variables_step{n})
            if ~iscell(retained_particle.var.(retained_particle.variables_step{n}{v}))
                intermediary_retained_particle.var.(retained_particle.variables_step{n}{v}) = ...
                    retained_particle.var.(retained_particle.variables_step{n}{v})(1:retained_particle.sizes_step{n}{v});
            else
                intermediary_retained_particle.var.(retained_particle.variables_step{n}{v}) = ...
                    {retained_particle.var.(retained_particle.variables_step{n}{v}){1}(1:retained_particle.sizes_step{n}{v})};
            end
        end        
        log_weights = [weighting_functions{n}(intermediary_retained_particle); % Retained particle weight
                       weighting_functions{n}(particles)];        % Other particle weights
        
        if n~=numel(sampling_functions)
            % At each step except the last, perform the conditional
            % resampling step of the particles.  This is broken up into
            % resampling of all the variables rather than treating seperate
            % particles as fully seperate indices for speed purposes.
            
            % Resample indices
            [i_resample, log_Z_step] = resample_step(log_weights, numel(log_weights)-1);
            log_Z = log_Z+log_Z_step;
            
            % New particle set the combination of the resampled indices and
            % the required number of replications of the retained particle.
            % Note that we are generating N-1 samples here,
            % with the retained particle completing the set
            i_take_new = i_resample(i_resample~=1)-1;
            n_ret = sum(i_resample==1);
            if n_ret==0
                var_fields = fields(particles.var);
                for n_f = 1:numel(var_fields)
                    particles.var.(var_fields{n_f}) = particles.var.(var_fields{n_f})(i_take_new,:);
                end
            else
                i_assign = 1:(N-1);
                particles = compose_two_sample_objects([],particles,intermediary_retained_particle,...
                    i_assign,numel(i_take_new),n_ret,[],[],i_take_new,ones(n_ret,1));
            end
        end
    end
    
    % Add the retained particle back into the final particle set
    particles = compose_two_sample_objects([],retained_particle,particles,1:N,1,N-1); 
    
    
    % Calculate the marginal likelihood and the relative particle weights
    z_max = max(log_weights);
    w = exp(log_weights-z_max);
    log_Z = log_Z+z_max+log(sum(w))-log(numel(w));
    particles.relative_particle_weights = w/sum(w);    
end

% Sample the new retained particle
i_keep = datasample(1:numel(particles.relative_particle_weights),1,'Weights',particles.relative_particle_weights,'Replace',true);
retained_particle = stack_object;
retained_particle.con = particles.con;
var_fields = fields(particles.var);
for n_f = 1:numel(var_fields)
    retained_particle.var.(var_fields{n_f}) = particles.var.(var_fields{n_f})(i_keep,:);
end
% Store the variables that exist at each step and their sizes
retained_particle.variables_step = variables_step;
retained_particle.sizes_step = sizes_step;
for n=1:numel(sampling_functions)
    if ~(numel(retained_particle.sizes_step{n})==1)
        retained_particle.sizes_step{n} = retained_particle.sizes_step{n}(i_keep);
    end
end

% Reset the sample_size variable
sample_size = N;

if ~b_Rao_Black
    particles = retained_particle;
    particles.relative_particle_weights = 1;
elseif b_compress
    particles = compress_samples(particles,numel(weighting_functions));
end

end