/* ============================================
   Azure Click Counter — Client Application
   ============================================ */

(function () {
    'use strict';

    // --- DOM Elements ---
    const ipAddressEl = document.getElementById('ipAddress');
    const totalCountEl = document.getElementById('totalCount');
    const ipCountEl = document.getElementById('ipCount');
    const clickBtn = document.getElementById('clickBtn');
    const clickHint = document.getElementById('clickHint');
    const activitySection = document.getElementById('activitySection');
    const activityFeed = document.getElementById('activityFeed');
    const rippleContainer = document.getElementById('rippleContainer');
    const particlesContainer = document.getElementById('particles');

    // --- State ---
    let isProcessing = false;
    let clientIp = null;
    const activityLog = [];
    const MAX_ACTIVITY_ITEMS = 10;

    // --- Initialize ---
    initParticles();
    detectIpThenLoad();
    clickBtn.addEventListener('click', handleClick);

    // --- IP Detection ---
    async function detectIpThenLoad() {
        try {
            const res = await fetch('https://api.ipify.org?format=json');
            if (res.ok) {
                const data = await res.json();
                clientIp = data.ip;
            }
        } catch (err) {
            console.warn('IP detection failed:', err);
        }
        loadCount();
    }

    // --- API Calls ---
    async function loadCount() {
        try {
            const url = clientIp ? `/api/count?ip=${encodeURIComponent(clientIp)}` : '/api/count';
            const res = await fetch(url);
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            const data = await res.json();
            updateUI(data);
        } catch (err) {
            console.error('Failed to load count:', err);
            ipAddressEl.textContent = 'Unavailable';
            totalCountEl.textContent = '—';
            ipCountEl.textContent = '—';
        }
    }

    async function handleClick(e) {
        if (isProcessing) return;
        isProcessing = true;

        // Visual feedback
        clickBtn.classList.add('clicking');
        createRipple(e);

        try {
            const body = clientIp ? JSON.stringify({ ipAddress: clientIp }) : undefined;
            const res = await fetch('/api/click', {
                method: 'POST',
                headers: body ? { 'Content-Type': 'application/json' } : {},
                body: body
            });
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            const data = await res.json();
            updateUI(data, true);
            addActivity(data.ipAddress);
        } catch (err) {
            console.error('Click failed:', err);
            showError('Click failed — please try again');
        } finally {
            isProcessing = false;
            setTimeout(() => clickBtn.classList.remove('clicking'), 500);
        }
    }

    // --- UI Updates ---
    function updateUI(data, animate = false) {
        ipAddressEl.textContent = data.ipAddress || 'Unknown';

        animateCounter(totalCountEl, data.totalCount, animate);
        animateCounter(ipCountEl, data.ipCount, animate);

        if (data.totalCount > 0) {
            clickHint.textContent = `${data.totalCount.toLocaleString()} total clicks recorded`;
        }
    }

    function animateCounter(el, newValue, animate) {
        const formatted = newValue.toLocaleString();
        el.textContent = formatted;

        if (animate) {
            el.classList.remove('animate');
            // Force reflow to restart animation
            void el.offsetWidth;
            el.classList.add('animate');
        }
    }

    function addActivity(ip) {
        activitySection.style.display = 'block';

        const now = new Date();
        const timeStr = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });

        activityLog.unshift({ ip, time: timeStr });
        if (activityLog.length > MAX_ACTIVITY_ITEMS) {
            activityLog.pop();
        }

        renderActivity();
    }

    function renderActivity() {
        activityFeed.innerHTML = '';
        activityLog.forEach((item, i) => {
            const el = document.createElement('div');
            el.className = 'activity-item';
            el.style.animationDelay = `${i * 0.05}s`;
            el.innerHTML = `
                <span class="activity-dot"></span>
                <span class="activity-text">Click from <strong>${escapeHtml(item.ip)}</strong></span>
                <span class="activity-time">${escapeHtml(item.time)}</span>
            `;
            activityFeed.appendChild(el);
        });
    }

    // --- Visual Effects ---
    function createRipple(e) {
        const rect = clickBtn.getBoundingClientRect();
        const x = rect.left + rect.width / 2;
        const y = rect.top + rect.height / 2;

        const ripple = document.createElement('div');
        ripple.className = 'ripple';
        ripple.style.width = '200px';
        ripple.style.height = '200px';
        ripple.style.left = `${x - 100}px`;
        ripple.style.top = `${y - 100}px`;
        rippleContainer.appendChild(ripple);

        setTimeout(() => ripple.remove(), 800);
    }

    function initParticles() {
        const count = window.innerWidth < 640 ? 20 : 40;
        for (let i = 0; i < count; i++) {
            const particle = document.createElement('div');
            particle.className = 'particle';
            particle.style.left = `${Math.random() * 100}%`;
            particle.style.animationDuration = `${8 + Math.random() * 12}s`;
            particle.style.animationDelay = `${Math.random() * 10}s`;
            particle.style.width = `${2 + Math.random() * 3}px`;
            particle.style.height = particle.style.width;
            particle.style.opacity = `${0.2 + Math.random() * 0.4}`;
            particlesContainer.appendChild(particle);
        }
    }

    // --- Error Toast ---
    function showError(message) {
        const existing = document.querySelector('.error-toast');
        if (existing) existing.remove();

        const toast = document.createElement('div');
        toast.className = 'error-toast';
        toast.textContent = message;
        document.body.appendChild(toast);

        setTimeout(() => {
            toast.classList.add('hide');
            setTimeout(() => toast.remove(), 300);
        }, 3000);
    }

    // --- Utility ---
    function escapeHtml(str) {
        const div = document.createElement('div');
        div.appendChild(document.createTextNode(str));
        return div.innerHTML;
    }
})();
