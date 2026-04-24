package models

// GetPath returns the storage base path.
func (s *Storage) GetPath() string {
	if s.Local != nil && s.Local.Path != "" {
		return s.Local.Path
	}
	return "/home/files"
}

// GetHost returns the storage host.
func (s *Storage) GetHost() string {
	if s.Local != nil {
		return s.Local.Host
	}
	return ""
}

// HasSSHCredentials checks if storage has valid SSH credentials.
func (s *Storage) HasSSHCredentials() bool {
	if s.Local == nil || s.Local.SSH == nil {
		return false
	}
	return s.Local.SSH.Username != "" && s.Local.SSH.Password != "" && s.Local.SSH.Port > 0
}

// IsOnline checks if storage is enabled and online.
func (s *Storage) IsOnline() bool {
	return s.Enable && s.Status == StorageStatusOnline
}
