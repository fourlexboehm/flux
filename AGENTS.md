avoid locks, allocations, and io on the audio thread
keep files < 1000 lines, logically break up new files to new folders / modules logically
when working with the audio engine, especially performance problems, test don't guess.
Try to reuse code and avoid overly verbose / slop code, we're trying to minize SLOC while stil keeping things readable, this means relying on existing C libraries where possible.
