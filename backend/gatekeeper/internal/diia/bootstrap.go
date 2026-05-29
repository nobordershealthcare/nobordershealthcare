package diia

import (
	"context"
	"fmt"
	"log/slog"
	"os"
)

// IDCache holds the branch and offer IDs required for both Diia scenarios.
// Populated once at startup by Bootstrap and injected into all flow handlers.
//
// IDs are sourced from env vars if available (preferred for production):
//
//	DIIA_BRANCH_ID         shared branch (or signing-specific branch)
//	DIIA_OFFER_ID_SIGNING  offer with scope hashedFilesSigning
//	DIIA_OFFER_ID_AUTH     offer with scope auth
//
// If any env var is empty, Bootstrap creates the corresponding resource via
// the Diia API and logs the IDs for operators to set in k8s secrets.
type IDCache struct {
	BranchID       string // shared acquirer branch
	SigningOfferID string // offer: DiiaID:["hashedFilesSigning"]
	AuthOfferID    string // offer: DiiaID:["auth"]
	CallbackURL    string // public callback URL registered in the branch
}

// Bootstrap initialises Diia branches and offers, reusing existing ones
// wherever possible to avoid recreating resources on every pod restart.
//
// Lookup order for each ID:
//  1. Environment variable (fastest path, no API calls).
//  2. Diia API list — reuse the first matching resource found.
//  3. Diia API create — create and log the new ID for operators.
//
// It is safe to call Bootstrap concurrently; only one pod needs to do the
// actual creation (Diia is idempotent on duplicate branch names).
func Bootstrap(ctx context.Context, client ClientInterface) (*IDCache, error) {
	callbackURL := os.Getenv("DIIA_CALLBACK_URL")

	cache := &IDCache{
		BranchID:       os.Getenv("DIIA_BRANCH_ID"),
		SigningOfferID: os.Getenv("DIIA_OFFER_ID_SIGNING"),
		AuthOfferID:    os.Getenv("DIIA_OFFER_ID_AUTH"),
		CallbackURL:    callbackURL,
	}

	// Fast path: all IDs already in env → skip all API calls.
	if cache.BranchID != "" && cache.SigningOfferID != "" && cache.AuthOfferID != "" {
		slog.Info("diia bootstrap: using branch/offer IDs from environment",
			slog.String("branch_id", cache.BranchID),
		)
		return cache, nil
	}

	// ── Branch ────────────────────────────────────────────────────────────
	if cache.BranchID == "" {
		id, err := ensureBranch(ctx, client, callbackURL)
		if err != nil {
			return nil, fmt.Errorf("diia bootstrap: branch: %w", err)
		}
		cache.BranchID = id
		slog.Info("diia bootstrap: branch ready",
			slog.String("branch_id", id),
			slog.String("hint", "set DIIA_BRANCH_ID="+id+" in k8s secrets to skip API calls on restart"),
		)
	}

	// ── Signing offer ─────────────────────────────────────────────────────
	if cache.SigningOfferID == "" {
		id, err := ensureOffer(ctx, client, cache.BranchID, "hashedFilesSigning")
		if err != nil {
			return nil, fmt.Errorf("diia bootstrap: signing offer: %w", err)
		}
		cache.SigningOfferID = id
		slog.Info("diia bootstrap: signing offer ready",
			slog.String("offer_id", id),
			slog.String("hint", "set DIIA_OFFER_ID_SIGNING="+id),
		)
	}

	// ── Auth offer ────────────────────────────────────────────────────────
	if cache.AuthOfferID == "" {
		id, err := ensureOffer(ctx, client, cache.BranchID, "auth")
		if err != nil {
			return nil, fmt.Errorf("diia bootstrap: auth offer: %w", err)
		}
		cache.AuthOfferID = id
		slog.Info("diia bootstrap: auth offer ready",
			slog.String("offer_id", id),
			slog.String("hint", "set DIIA_OFFER_ID_AUTH="+id),
		)
	}

	return cache, nil
}

// ensureBranch returns the first existing branch ID, or creates a new one.
func ensureBranch(ctx context.Context, client ClientInterface, callbackURL string) (string, error) {
	branches, err := client.GetBranches(ctx)
	if err != nil {
		slog.Warn("diia bootstrap: list branches failed, will create new",
			slog.String("err", err.Error()),
		)
	}
	if len(branches) > 0 {
		slog.Info("diia bootstrap: reusing existing branch", slog.String("id", branches[0].ID))
		return branches[0].ID, nil
	}

	b, err := client.CreateBranch(ctx, CreateBranchRequest{
		Name:             envOrDefault("DIIA_BRANCH_NAME", "NoBorders Healthcare"),
		Email:            envOrDefault("DIIA_BRANCH_EMAIL", "diia@noborders.healthcare"),
		Region:           "Київ",
		District:         "Шевченківський",
		Location:         "Київ",
		Street:           "вул. Хрещатик",
		House:            "1",
		DeliveryTypes:    []string{"api"},
		Scopes:           Scopes{DiiaID: []string{"hashedFilesSigning", "auth"}},
		CallbackEndpoint: callbackURL,
	})
	if err != nil {
		return "", fmt.Errorf("CreateBranch: %w", err)
	}
	return b.ID, nil
}

// ensureOffer returns the first existing offer matching the scope, or creates one.
func ensureOffer(ctx context.Context, client ClientInterface, branchID, scope string) (string, error) {
	offers, err := client.ListOffers(ctx, branchID)
	if err != nil {
		slog.Warn("diia bootstrap: list offers failed, will create new",
			slog.String("branch_id", branchID),
			slog.String("scope", scope),
			slog.String("err", err.Error()),
		)
	}
	for _, o := range offers {
		for _, s := range o.Scopes.DiiaID {
			if s == scope {
				slog.Info("diia bootstrap: reusing existing offer",
					slog.String("offer_id", o.ID),
					slog.String("scope", scope),
				)
				return o.ID, nil
			}
		}
	}

	name := "NoBorders " + scope
	o, err := client.CreateOffer(ctx, branchID, CreateOfferRequest{
		Name:   name,
		Scopes: Scopes{DiiaID: []string{scope}},
	})
	if err != nil {
		return "", fmt.Errorf("CreateOffer scope=%s: %w", scope, err)
	}
	return o.ID, nil
}
