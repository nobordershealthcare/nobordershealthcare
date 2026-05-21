package main

import "errors"

var (
	ErrInvalidHash    = errors.New("input must be a 64-character lowercase SHA3-256 hex string")
	ErrInvalidRole    = errors.New("role must be one of: patient, guardian, er_doctor, insurer, researcher, admin")
	ErrRecordExists   = errors.New("an active access grant already exists for this (user, doc, role) tuple")
	ErrRecordNotFound = errors.New("no access record found for the given (user, doc, role) tuple")
	ErrAccessRevoked  = errors.New("access grant has been revoked")
	ErrNotAdmin       = errors.New("caller must hold the 'admin' role attribute in their enrollment certificate")
	ErrSameAdmin      = errors.New("co-signer hash must differ from the submitting admin's certificate hash")
	ErrNotOwner       = errors.New("caller certificate hash does not match the supplied userHash")
)
