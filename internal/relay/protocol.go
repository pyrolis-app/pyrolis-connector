package relay

import (
	"encoding/json"
	"fmt"
	"strconv"
	"sync/atomic"
)

// Message represents a Phoenix Channels v2 wire message.
// Wire format: [join_ref, ref, topic, event, payload]
type Message struct {
	JoinRef interface{}            // string or nil
	Ref     interface{}            // string or nil
	Topic   string
	Event   string
	Payload map[string]interface{}
}

// refCounter is an atomic counter for generating unique message refs.
var refCounter atomic.Int64

// nextRef returns the next unique ref as a string.
func nextRef() string {
	return strconv.FormatInt(refCounter.Add(1), 10)
}

// Encode serializes a Message to the Phoenix Channels v2 JSON array format.
func (m *Message) Encode() ([]byte, error) {
	arr := []interface{}{m.JoinRef, m.Ref, m.Topic, m.Event, m.Payload}
	return json.Marshal(arr)
}

// DecodeMessage parses a Phoenix Channels v2 JSON array into a Message.
func DecodeMessage(data []byte) (*Message, error) {
	var arr []json.RawMessage
	if err := json.Unmarshal(data, &arr); err != nil {
		return nil, fmt.Errorf("decode message array: %w", err)
	}
	if len(arr) != 5 {
		return nil, fmt.Errorf("expected 5 elements, got %d", len(arr))
	}

	msg := &Message{}

	// join_ref (index 0) — string or null
	msg.JoinRef = decodeNullableString(arr[0])

	// ref (index 1) — string or null
	msg.Ref = decodeNullableString(arr[1])

	// topic (index 2) — string
	if err := json.Unmarshal(arr[2], &msg.Topic); err != nil {
		return nil, fmt.Errorf("decode topic: %w", err)
	}

	// event (index 3) — string
	if err := json.Unmarshal(arr[3], &msg.Event); err != nil {
		return nil, fmt.Errorf("decode event: %w", err)
	}

	// payload (index 4) — object
	if err := json.Unmarshal(arr[4], &msg.Payload); err != nil {
		// Try as nested reply: {"status": "ok", "response": {...}}
		msg.Payload = make(map[string]interface{})
		json.Unmarshal(arr[4], &msg.Payload)
	}

	return msg, nil
}

// decodeNullableString decodes a JSON value that is either a string or null.
func decodeNullableString(raw json.RawMessage) interface{} {
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	return nil
}

// NewJoinMessage creates a phx_join message for a topic.
func NewJoinMessage(topic string) *Message {
	ref := nextRef()
	return &Message{
		JoinRef: ref,
		Ref:     ref,
		Topic:   topic,
		Event:   "phx_join",
		Payload: map[string]interface{}{},
	}
}

// NewHeartbeat creates a Phoenix heartbeat message.
func NewHeartbeat() *Message {
	return &Message{
		JoinRef: nil,
		Ref:     nextRef(),
		Topic:   "phoenix",
		Event:   "heartbeat",
		Payload: map[string]interface{}{},
	}
}

// NewPush creates a message to push an event on a topic.
func NewPush(joinRef string, topic, event string, payload map[string]interface{}) *Message {
	return &Message{
		JoinRef: joinRef,
		Ref:     nextRef(),
		Topic:   topic,
		Event:   event,
		Payload: payload,
	}
}

// ReplyStatus extracts the status from a phx_reply payload.
// Reply payload format: {"status": "ok", "response": {...}}
func (m *Message) ReplyStatus() string {
	if m.Event != "phx_reply" {
		return ""
	}
	if s, ok := m.Payload["status"].(string); ok {
		return s
	}
	return ""
}

// ReplyResponse extracts the response from a phx_reply payload.
func (m *Message) ReplyResponse() map[string]interface{} {
	if m.Event != "phx_reply" {
		return nil
	}
	if r, ok := m.Payload["response"].(map[string]interface{}); ok {
		return r
	}
	return nil
}
