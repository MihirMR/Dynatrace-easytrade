package flag

import "testing"

// Setting a variable to "" makes getEnvBool fall back to its default, so the
// cases below see the shipped defaults whatever the host environment holds.

const initTestPortfolioInsightsID = "portfolio-insights-enabled"

func initTestPortfolioInsightsFlag(t *testing.T) *Flag {
	t.Helper()
	f, ok := InitFlags()[initTestPortfolioInsightsID]
	if !ok {
		t.Fatalf("expected flag %s to be initialised", initTestPortfolioInsightsID)
	}
	return f
}

func TestInitFlags_portfolioInsights_defaultDisabled(t *testing.T) {
	t.Setenv("ENABLE_PORTFOLIO_INSIGHTS", "")
	f := initTestPortfolioInsightsFlag(t)
	if f.Enabled {
		t.Errorf("expected enabled false, got %v", f.Enabled)
	}
	if f.EnabledAt != nil {
		t.Errorf("expected enabledAt nil, got %v", f.EnabledAt)
	}
}

func TestInitFlags_portfolioInsightsEnvTrue_enabled(t *testing.T) {
	t.Setenv("ENABLE_PORTFOLIO_INSIGHTS", "true")
	f := initTestPortfolioInsightsFlag(t)
	if !f.Enabled {
		t.Errorf("expected enabled true, got %v", f.Enabled)
	}
	if f.EnabledAt == nil {
		t.Error("expected enabledAt to be set, got nil")
	}
}

func TestInitFlags_portfolioInsights_featureTagModifiable(t *testing.T) {
	t.Setenv("ENABLE_MODIFY", "")
	f := initTestPortfolioInsightsFlag(t)
	if f.ID != initTestPortfolioInsightsID {
		t.Errorf("expected id %s, got %s", initTestPortfolioInsightsID, f.ID)
	}
	if f.Tag != "feature" {
		t.Errorf("expected tag feature, got %s", f.Tag)
	}
	if !f.IsModifiable {
		t.Errorf("expected isModifiable true, got %v", f.IsModifiable)
	}
	if f.Name != "Portfolio insights" {
		t.Errorf("expected name Portfolio insights, got %s", f.Name)
	}
}

func TestInitFlags_enableModifyFalse_portfolioInsightsNotModifiable(t *testing.T) {
	t.Setenv("ENABLE_MODIFY", "false")
	f := initTestPortfolioInsightsFlag(t)
	if f.IsModifiable {
		t.Errorf("expected isModifiable false, got %v", f.IsModifiable)
	}
}

func TestInitFlags_problemPatternTag_excludesPortfolioInsights(t *testing.T) {
	flags := NewService(InitFlags()).GetByTag("problem_pattern")
	if len(flags) != 7 {
		t.Errorf("expected 7 problem_pattern flags, got %d", len(flags))
	}
	for _, f := range flags {
		if f.ID == initTestPortfolioInsightsID {
			t.Errorf("expected %s to be absent from problem_pattern flags", initTestPortfolioInsightsID)
		}
	}
}

func TestInitFlags_existingFlags_unchanged(t *testing.T) {
	for _, key := range []string{
		"ENABLE_MODIFY",
		"ENABLE_FRONTEND_MODIFY",
		"ENABLE_DB_NOT_RESPONDING",
		"ENABLE_ERGO_AGGREGATOR_SLOWDOWN",
		"ENABLE_FACTORY_CRISIS",
		"ENABLE_CREDIT_CARD_MELTDOWN",
		"ENABLE_CREDIT_CARD_MEMORY_LEAK",
		"ENABLE_HIGH_CPU_USAGE",
		"ENABLE_CREDIT_CARD_VALIDATION",
	} {
		t.Setenv(key, "")
	}

	expected := []struct {
		id           string
		enabled      bool
		tag          string
		isModifiable bool
	}{
		{id: "frontend_feature_flag_management", enabled: true, tag: "config", isModifiable: false},
		{id: "db_not_responding", enabled: false, tag: "problem_pattern", isModifiable: true},
		{id: "ergo_aggregator_slowdown", enabled: false, tag: "problem_pattern", isModifiable: true},
		{id: "factory_crisis", enabled: false, tag: "problem_pattern", isModifiable: true},
		{id: "credit_card_meltdown", enabled: false, tag: "problem_pattern", isModifiable: true},
		{id: "credit_card_memory_leak", enabled: false, tag: "problem_pattern", isModifiable: true},
		{id: "high_cpu_usage", enabled: false, tag: "problem_pattern", isModifiable: true},
		{id: "credit_card_validation", enabled: false, tag: "problem_pattern", isModifiable: true},
	}

	flags := InitFlags()
	if len(flags) != 9 {
		t.Errorf("expected 9 flags, got %d", len(flags))
	}
	for _, want := range expected {
		f, ok := flags[want.id]
		if !ok {
			t.Errorf("expected flag %s to be initialised", want.id)
			continue
		}
		if f.ID != want.id {
			t.Errorf("flag %s: expected id %s, got %s", want.id, want.id, f.ID)
		}
		if f.Enabled != want.enabled {
			t.Errorf("flag %s: expected enabled %v, got %v", want.id, want.enabled, f.Enabled)
		}
		if f.Tag != want.tag {
			t.Errorf("flag %s: expected tag %s, got %s", want.id, want.tag, f.Tag)
		}
		if f.IsModifiable != want.isModifiable {
			t.Errorf("flag %s: expected isModifiable %v, got %v", want.id, want.isModifiable, f.IsModifiable)
		}
	}
}
