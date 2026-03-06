package i18n

import (
	"strings"
	"sync"
)

var (
	mu     sync.RWMutex
	locale = "en"
)

// SetLocale sets the current locale (en or fr).
func SetLocale(l string) {
	mu.Lock()
	defer mu.Unlock()
	if l == "fr" || strings.HasPrefix(l, "fr-") {
		locale = "fr"
	} else {
		locale = "en"
	}
}

// GetLocale returns the current locale.
func GetLocale() string {
	mu.RLock()
	defer mu.RUnlock()
	return locale
}

// DetectLocale picks locale from Accept-Language header.
func DetectLocale(acceptLang string) string {
	if strings.Contains(strings.ToLower(acceptLang), "fr") {
		return "fr"
	}
	return "en"
}

// T translates a message ID to the current locale.
func T(msgID string) string {
	mu.RLock()
	l := locale
	mu.RUnlock()

	if l == "fr" {
		if v, ok := messagesFR[msgID]; ok && v != "" {
			return v
		}
	}
	// Fallback to English (which is the msgID itself for most strings)
	if v, ok := messagesEN[msgID]; ok {
		return v
	}
	return msgID
}

// TL translates with an explicit locale.
func TL(lang, msgID string) string {
	if lang == "fr" || strings.HasPrefix(lang, "fr-") {
		if v, ok := messagesFR[msgID]; ok && v != "" {
			return v
		}
	}
	if v, ok := messagesEN[msgID]; ok {
		return v
	}
	return msgID
}
