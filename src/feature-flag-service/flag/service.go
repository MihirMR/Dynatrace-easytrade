package flag

import (
	"sync"
)

type Service struct {
	mu    sync.RWMutex
	flags map[string]*Flag
}

func NewService(flags map[string]*Flag) *Service {
	return &Service{flags: flags}
}

// snapshot returns a copy of a stored flag so callers can serialise it after
// the lock is released while Update writes the stored value. Callers must hold
// the Service lock. A shallow copy suffices: SetEnabled replaces EnabledAt
// rather than writing through it.
func snapshot(f *Flag) *Flag {
	c := *f
	return &c
}

func (s *Service) GetByID(id string) (*Flag, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	f, ok := s.flags[id]
	if !ok {
		return nil, false
	}
	return snapshot(f), true
}

func (s *Service) GetAll() []*Flag {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]*Flag, 0, len(s.flags))
	for _, f := range s.flags {
		result = append(result, snapshot(f))
	}
	return result
}

func (s *Service) GetByTag(tag string) []*Flag {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]*Flag, 0)
	for _, f := range s.flags {
		if f.Tag == tag {
			result = append(result, snapshot(f))
		}
	}
	return result
}

func (s *Service) Update(id string, enabled bool) (*Flag, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f, ok := s.flags[id]
	if !ok {
		return nil, ErrFlagNotFound
	}
	if err := f.SetEnabled(enabled); err != nil {
		return nil, err
	}
	return snapshot(f), nil
}
