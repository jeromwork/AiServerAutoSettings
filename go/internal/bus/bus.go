// Package bus mirrors v2 bus.py: a non-blocking event queue with one dispatcher goroutine.
// No timers by design (constitution 5b: events, not timers).
package bus

import (
	"fmt"
	"sync"

	"remoteagents/internal/api"
)

const (
	queueMax   = 1000
	queueReset = 500
)

// lastTopics: Last() works only for these topics.
var lastTopics = map[string]bool{"agent.ready": true, "singbox.started": true, "channel.up": true}

// Event is one published event.
type Event struct {
	Topic string
	Data  map[string]any
}

type sub struct {
	id int
	fn func(Event)
}

// Bus delivers events to subscribers in order from a single goroutine.
type Bus struct {
	log      api.Logger
	q        chan Event
	stop     chan struct{}
	done     chan struct{}
	mu       sync.Mutex
	subs     map[string][]sub
	last     map[string]map[string]any
	nextID   int
	overflow bool
	closed   bool
}

// New starts the dispatcher. A nil logger is allowed.
func New(log api.Logger) *Bus {
	b := &Bus{log: log, q: make(chan Event, queueMax), stop: make(chan struct{}), done: make(chan struct{}),
		subs: map[string][]sub{}, last: map[string]map[string]any{}}
	go b.run()
	return b
}

// Publish never blocks: a full queue drops the event (overflow is logged once until the queue falls to 500).
// Safe on a nil *Bus.
func (b *Bus) Publish(topic string, data map[string]any) {
	if b == nil {
		return
	}
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	if lastTopics[topic] {
		b.last[topic] = data
	}
	first := false
	select {
	case b.q <- Event{topic, data}:
	default:
		first, b.overflow = !b.overflow, true
	}
	b.mu.Unlock()
	if first && b.log != nil {
		b.log.Warn("bus.queue.overflow", "max", queueMax, "dropped_topic", topic)
	}
}

// Subscribe registers fn for an exact topic; the returned func removes it.
func (b *Bus) Subscribe(topic string, fn func(Event)) (unsubscribe func()) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return func() {}
	}
	b.nextID++
	id := b.nextID
	b.subs[topic] = append(b.subs[topic], sub{id, fn})
	return func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		list := b.subs[topic]
		for i, s := range list {
			if s.id == id {
				b.subs[topic] = append(append([]sub(nil), list[:i]...), list[i+1:]...)
				return
			}
		}
	}
}

// Last returns the last data of a topic from lastTopics (nil otherwise).
func (b *Bus) Last(topic string) map[string]any {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.last[topic]
}

// Close cancels dispatch and waits for the current callback to finish. Queued
// events are discarded; Publish and Subscribe become no-ops. Call outside callbacks.
func (b *Bus) Close() {
	if b == nil {
		return
	}
	b.mu.Lock()
	if !b.closed {
		b.closed = true
		close(b.stop)
	}
	b.mu.Unlock()
	<-b.done
}

func (b *Bus) run() {
	defer close(b.done)
	for {
		var ev Event
		select {
		case <-b.stop:
			return
		case ev = <-b.q:
		}
		b.mu.Lock()
		if b.closed {
			b.mu.Unlock()
			return
		}
		if b.overflow && len(b.q) <= queueReset {
			b.overflow = false
		}
		subs := append([]sub(nil), b.subs[ev.Topic]...)
		b.mu.Unlock()
		if b.log != nil {
			b.log.Info(ev.Topic, "data", ev.Data)
		}
		for _, s := range subs {
			select {
			case <-b.stop:
				return
			default:
			}
			b.safe(ev, s.fn)
		}
	}
}

func (b *Bus) safe(ev Event, fn func(Event)) {
	defer func() {
		if r := recover(); r != nil && b.log != nil {
			b.log.Error("bus.subscriber.error", "topic", ev.Topic, "panic", fmt.Sprint(r))
		}
	}()
	fn(ev)
}
