using System.Diagnostics.Metrics;

namespace SuperApp.Observability;

/// <summary>
/// Centralised Prometheus/OTel metric instruments for all Mobile App KPIs.
/// Aligned to Republic Bank Ghana Channel Performance KPI Framework.
///
/// Usage: Register via AddSingleton<MobileKpiMetrics>() then inject and call
/// the Track* methods at the relevant application events.
///
/// KPI Reference:
///   KPI-1: ActiveUsersRatio      KPI-5: SystemAvailability
///   KPI-2: AdoptionRate          KPI-6: FailedTransactionRate
///   KPI-3: TransactionVolume     KPI-7: LoginFrequency
///   KPI-4: TransactionValue      KPI-8: CustomerSatisfaction/NPS
/// </summary>
public sealed class MobileKpiMetrics : IDisposable
{
    public static readonly string MeterName = "SuperApp.Mobile";

    private readonly Meter _meter;

    // ── KPI-3: Transaction Volume ────────────────────────────────────────
    private readonly Counter<long>        _transactionTotal;
    private readonly Counter<long>        _transactionFailed;

    // ── KPI-4: Transaction Value (GHS) ───────────────────────────────────
    private readonly Counter<double>      _transactionValueGhs;

    // ── KPI-5: System Availability (implicit from up/down) ────────────────
    // Tracked via Prometheus `up` metric automatically by health check scraper

    // ── KPI-2: User Registrations (Adoption Rate driver) ─────────────────
    private readonly Counter<long>        _userRegistrations;

    // ── KPI-7: Login Events ───────────────────────────────────────────────
    private readonly Counter<long>        _userLogins;

    // ── KPI-1: Active Sessions / Users ───────────────────────────────────
    private readonly UpDownCounter<long>  _activeSessions;
    private readonly ObservableGauge<long> _registeredUsers;
    private          long                 _registeredUsersValue;

    // ── KPI-8: NPS Score ─────────────────────────────────────────────────
    private readonly ObservableGauge<double> _npsScore;
    private          double                  _currentNps;

    // ── Wallet balance ────────────────────────────────────────────────────
    private readonly ObservableGauge<double> _totalWalletBalance;
    private          double                  _walletBalance;

    // ── API performance (latency histogram, error rates) ──────────────────
    private readonly Histogram<double>    _apiRequestDuration;
    private readonly Counter<long>        _apiRequestsTotal;
    private readonly Counter<long>        _apiErrors;

    // ── Channel migration ────────────────────────────────────────────────
    private readonly Counter<long>        _transactionsByChannel;

    public MobileKpiMetrics(IMeterFactory meterFactory)
    {
        _meter = meterFactory.Create(MeterName, "1.0.0");

        // KPI-3: Transaction counters
        _transactionTotal   = _meter.CreateCounter<long>(
            "superapp_payment_transactions_total",
            unit: "{transactions}",
            description: "KPI-3: Total payment transactions initiated via mobile channel");

        _transactionFailed  = _meter.CreateCounter<long>(
            "superapp_payment_transactions_failed_total",
            unit: "{transactions}",
            description: "KPI-6: Total failed payment transactions");

        // KPI-4: Transaction value
        _transactionValueGhs = _meter.CreateCounter<double>(
            "superapp_payment_transaction_value_ghs_total",
            unit: "GHS",
            description: "KPI-4: Total value of mobile payment transactions in GHS");

        // KPI-2: Registration (adoption)
        _userRegistrations = _meter.CreateCounter<long>(
            "superapp_user_registrations_total",
            unit: "{users}",
            description: "KPI-2: Total new user registrations (mobile digital enrollment)");

        // KPI-7: Logins
        _userLogins = _meter.CreateCounter<long>(
            "superapp_user_login_total",
            unit: "{logins}",
            description: "KPI-7: Total user login events (tracks login frequency)");

        // KPI-1: Sessions
        _activeSessions = _meter.CreateUpDownCounter<long>(
            "superapp_active_sessions_gauge",
            unit: "{sessions}",
            description: "KPI-1: Current active mobile sessions");

        _registeredUsers = _meter.CreateObservableGauge<long>(
            "superapp_registered_users_total",
            () => _registeredUsersValue,
            unit: "{users}",
            description: "KPI-1: Total registered mobile users");

        // KPI-8: NPS
        _npsScore = _meter.CreateObservableGauge<double>(
            "superapp_nps_score_gauge",
            () => _currentNps,
            unit: "score",
            description: "KPI-8: Current Net Promoter Score (survey-based)");

        // Wallet total balance
        _totalWalletBalance = _meter.CreateObservableGauge<double>(
            "superapp_wallet_balance_ghs_gauge",
            () => _walletBalance,
            unit: "GHS",
            description: "Total wallet balance across all active wallets");

        // API latency histogram
        _apiRequestDuration = _meter.CreateHistogram<double>(
            "http_server_request_duration_seconds",
            unit: "s",
            description: "HTTP request duration in seconds");

        _apiRequestsTotal = _meter.CreateCounter<long>(
            "superapp_api_requests_total",
            unit: "{requests}",
            description: "Total API requests by service and status");

        _apiErrors = _meter.CreateCounter<long>(
            "superapp_api_errors_total",
            unit: "{errors}",
            description: "Total API errors by service and error code");

        // Channel migration
        _transactionsByChannel = _meter.CreateCounter<long>(
            "superapp_payment_transactions_by_channel_total",
            unit: "{transactions}",
            description: "Transactions by channel (digital, branch, ATM) for migration rate");
    }

    // ── KPI-3 & KPI-4 & KPI-6: Record a payment transaction ─────────────
    public void TrackTransaction(
        string status,      // "completed" | "failed" | "pending"
        decimal amountGhs,
        string rail,        // "GhIPSS" | "ExpressPay" | "InternalTransfer"
        string userId,
        string channel = "mobile")
    {
        var tags = new TagList
        {
            { "status",  status  },
            { "rail",    rail    },
            { "channel", channel }
        };

        _transactionTotal.Add(1, tags);
        _transactionsByChannel.Add(1, new TagList { { "channel", channel } });

        if (status == "failed")
            _transactionFailed.Add(1, tags);

        if (status == "completed" && amountGhs > 0)
            _transactionValueGhs.Add((double)amountGhs, tags);
    }

    // ── KPI-2: Record a new user registration ────────────────────────────
    public void TrackUserRegistration(string tier = "Basic")
    {
        _userRegistrations.Add(1, new TagList { { "tier", tier }, { "channel", "mobile" } });
        System.Threading.Interlocked.Increment(ref _registeredUsersValue);
    }

    // ── KPI-7: Record a login event ───────────────────────────────────────
    public void TrackLogin(string userId, string tier = "Basic")
    {
        _userLogins.Add(1, new TagList { { "tier", tier } });
    }

    // ── KPI-1: Track active session start/end ────────────────────────────
    public void SessionStarted(string userId) =>
        _activeSessions.Add(1,  new TagList { { "channel", "mobile" } });

    public void SessionEnded(string userId) =>
        _activeSessions.Add(-1, new TagList { { "channel", "mobile" } });

    // ── KPI-8: Update NPS score ───────────────────────────────────────────
    public void UpdateNps(double npsScore) => _currentNps = npsScore;

    // ── Update total wallet balance ───────────────────────────────────────
    public void UpdateTotalWalletBalance(decimal balanceGhs) =>
        _walletBalance = (double)balanceGhs;

    // ── Track API request (latency + status) ─────────────────────────────
    public void TrackApiRequest(
        string service,
        string method,
        int statusCode,
        double durationSeconds,
        string? errorCode = null)
    {
        var tags = new TagList
        {
            { "service",     service    },
            { "http_method", method     },
            { "status_code", statusCode }
        };

        _apiRequestDuration.Record(durationSeconds, tags);
        _apiRequestsTotal.Add(1, tags);

        if (statusCode >= 400)
        {
            _apiErrors.Add(1, new TagList
            {
                { "service",    service             },
                { "error_code", errorCode ?? "unknown" },
                { "status",     statusCode          }
            });
        }
    }

    public void Dispose() => _meter.Dispose();
}
