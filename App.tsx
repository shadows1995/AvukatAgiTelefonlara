import React, { useRef, useState, useEffect, useCallback } from 'react';
import {
  SafeAreaView,
  StatusBar,
  BackHandler,
  View,
  TouchableOpacity,
  Text,
  ActivityIndicator,
  Platform,
  StyleSheet,
} from 'react-native';
import { WebView } from 'react-native-webview';
import { Home, Search, PlusCircle, Briefcase, User, RefreshCw, Smartphone } from 'lucide-react-native';
import './src/global.css'; // Ensure NativeWind styles are applied if set up, mostly standard RN logic here

// --- Configuration ---
const URLs = {
  home: 'https://avukatagi.net/#/home',
  dashboard: 'https://avukatagi.net/#/dashboard', // "Görev Bul"
  create: 'https://avukatagi.net/#/create-job',
  myJobs: 'https://avukatagi.net/#/my-jobs',
  profile: 'https://avukatagi.net/#/profile/',
  login: 'https://avukatagi.net/#/login',
  base: 'https://avukatagi.net',
};

// --- Injected Scripts ---
// This script moves the hamburger menu from right to left using CSS overrides.
const INJECTED_JAVASCRIPT = `
(function() {
  // Add the marker class to body
  document.body.classList.add('avukat-agi-mobile-app');

  // Inject Custom CSS (Static Overrides)
  const style = document.createElement('style');
  style.textContent = \`
    /* SCALE FIX: Zoom out the UI to make it look native-sized */
    body.avukat-agi-mobile-app {
        zoom: 0.85; 
        -webkit-text-size-adjust: 100%;
    }

    /* Force Generic Fixed/Right Elements to Left (Backup) */
    body.avukat-agi-mobile-app .fixed.right-0,
    body.avukat-agi-mobile-app .absolute.right-0 {
        right: auto !important;
        left: 0 !important;
    }
    
    /* Animation Fix */
    body.avukat-agi-mobile-app .translate-x-full {
        --tw-translate-x: -100% !important;
        transform: translateX(-100%) !important;
    }
    
    /* Specific Override for Common Sidebars */
    [class*="right-0"] {
       right: auto !important;
       left: 0 !important;
    }

    /* Hide scrollbar */
    ::-webkit-scrollbar {
      width: 0px;
      background: transparent;
    }
  \`;
  document.head.appendChild(style);

  // --- ACTIVE HACK: MutationObserver to Catch Dynamic Menu ---
  // The menu is likely a dynamic React Portal. We watch for it and force it left.
  const observer = new MutationObserver((mutations) => {
    mutations.forEach((mutation) => {
      mutation.addedNodes.forEach((node) => {
        if (node.nodeType === 1) { // Element node
             // Check if it's a fixed sidebar-like element
             const el = node;
             const isFixed = el.classList.contains('fixed') || el.classList.contains('absolute');
             // Also check for specific Tailwind classes often used for sidebars
             const isSidebar = el.classList.contains('z-50') || el.classList.contains('z-40') || el.innerHTML.includes('menu');
             
             if (isFixed && isSidebar) {
                 // FORCE LEFT
                 el.style.right = 'auto';
                 el.style.left = '0px';
                 
                 // If it uses translate-x (transform), flip it
                 if (el.classList.contains('translate-x-full')) {
                     el.style.transform = 'translateX(-100%)';
                 } else if (el.style.transform.includes('100%')) {
                     el.style.transform = 'translateX(-100%)';
                 } else {
                    // Start hidden if needed (optional)
                 }
                 
                 // Add a marker so we know we got it
                 el.setAttribute('data-hacked-sidebar', 'true');
             }
        }
      });
    });
  });
  
  // Start observing body for added sidebars
  observer.observe(document.body, { childList: true, subtree: true });

  // --- Profile ID Extraction ---
  setInterval(() => {
    try {
        let userId = null;
        for (let i = 0; i < localStorage.length; i++) {
            const key = localStorage.key(i);
            if (key && key.startsWith('sb-') && key.endsWith('-auth-token')) {
                const session = JSON.parse(localStorage.getItem(key));
                if (session && session.user && session.user.id) {
                    userId = session.user.id;
                    break;
                }
            }
        }
        if (userId) {
            window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'USER_ID', payload: userId }));
        }
    } catch (e) {}
  }, 2000);
})();
true; 
`;

export default function App() {
  // --- Refs & State ---
  const webViewRef = useRef<WebView>(null);
  const [currentUrl, setCurrentUrl] = useState(URLs.home);
  // Dynamic Profile URL Helper
  const [profileId, setProfileId] = useState<string | null>(null);

  const [canGoBack, setCanGoBack] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [hasError, setHasError] = useState(false);

  // --- Handlers ---

  // Handle Android Hardware Back Button
  useEffect(() => {
    const onBackPress = () => {
      if (canGoBack && webViewRef.current) {
        webViewRef.current.goBack();
        return true; // Handled
      }
      return false; // Default behavior (exit app)
    };

    const subscription = BackHandler.addEventListener('hardwareBackPress', onBackPress);
    return () => subscription.remove();
  }, [canGoBack]);

  // Navigate to a specific URL (triggered by Bottom Tab)
  const navigateTo = (url: string) => {
    // Special handling for Profile
    if (url === URLs.profile) {
      if (profileId) {
        setCurrentUrl(URLs.base + '/#/profile/' + profileId);
      } else {
        // Fallback if no ID found yet 
        setCurrentUrl(URLs.base + '/#/profile/');
      }
    } else {
      setCurrentUrl(url);
    }
    setHasError(false);
  };

  const handleMessage = (event: any) => {
    try {
      const data = JSON.parse(event.nativeEvent.data);
      if (data.type === 'USER_ID' && data.payload) {
        setProfileId(data.payload);
      }
    } catch (e) {
      // Ignore
    }
  };

  const handleReload = () => {
    if (webViewRef.current) {
      setHasError(false);
      webViewRef.current.reload();
    }
  };

  // --- Render Helpers ---

  // Custom Tab Bar Item
  const TabItem = ({
    icon: Icon,
    label,
    targetUrl,
    isActive,
    isFloating = false
  }: { icon: any, label?: string, targetUrl: string, isActive: boolean, isFloating?: boolean }) => {

    // Floating Action Button Style (Center +)
    if (isFloating) {
      return (
        <View className="relative -top-6 items-center justify-center">
          <TouchableOpacity
            onPress={() => navigateTo(targetUrl)}
            className="w-16 h-16 bg-[#5b50f7] rounded-full items-center justify-center shadow-lg elevation-8"
            activeOpacity={0.9}
          >
            <Icon size={32} color="#ffffff" strokeWidth={2.5} />
          </TouchableOpacity>
        </View>
      );
    }

    // Standard Tab Item
    return (
      <TouchableOpacity
        onPress={() => navigateTo(targetUrl)}
        className="flex-1 items-center justify-center py-2"
        activeOpacity={0.7}
      >
        <Icon
          size={26}
          color={isActive ? '#5b50f7' : '#94a3b8'} // Custom Purple vs Slate-400
          strokeWidth={isActive ? 2.5 : 2}
        />
        <Text className={`text-[10px] mt-1 font-medium ${isActive ? 'text-[#5b50f7]' : 'text-slate-400'}`}>
          {label}
        </Text>
      </TouchableOpacity>
    );
  };

  // Logic to hide tab bar on auth pages and landing page
  const isAuthPage = currentUrl.includes('/login') || currentUrl.includes('/register') || currentUrl.includes('/forgot-password');
  // Check for landing page (exact #/ or just base)
  const isLandingPage = currentUrl.endsWith('/#/') || currentUrl === URLs.base || currentUrl === URLs.base + '/';

  const shouldShowTabBar = !isAuthPage && !isLandingPage;

  return (
    <SafeAreaView className="flex-1 bg-white">
      <StatusBar barStyle="dark-content" backgroundColor="#ffffff" />

      {/* WebView Container */}
      <View className="flex-1 relative bg-slate-50">
        <WebView
          ref={webViewRef}
          source={{ uri: currentUrl }}
          className="flex-1"
          javaScriptEnabled={true}
          domStorageEnabled={true}
          injectedJavaScript={INJECTED_JAVASCRIPT}
          onMessage={handleMessage}
          allowsBackForwardNavigationGestures={true}
          userAgent={Platform.select({
            ios: "AvukatAgiPhone/1.0 (iOS)",
            android: "AvukatAgiPhone/1.0 (Android)"
          })}
          onLoadStart={() => {
            setIsLoading(true);
            setHasError(false);
          }}
          onLoadEnd={() => setIsLoading(false)}
          onError={() => {
            setIsLoading(false);
            setHasError(true);
          }}
          onNavigationStateChange={(navState) => {
            setCanGoBack(navState.canGoBack);
            // Sync state with navigation to handle back button/menu visibility
            // We only update if the URL actually changes to avoid loops
            if (navState.url && navState.url !== currentUrl) {
              setCurrentUrl(navState.url);
            }
          }}
        />

        {/* Loading Indicator */}
        {isLoading && (
          <View className="absolute top-0 w-full h-1 is-loading-bar bg-white">
            {/* Simple Top Progress Bar could go here, or just a centered spinner */}
            <View className="absolute inset-0 flex items-center justify-center bg-white/50 backdrop-blur-sm z-10 h-full">
              <ActivityIndicator size="large" color="#5b50f7" />
            </View>
          </View>
        )}

        {/* Error State */}
        {hasError && (
          <View className="absolute inset-0 bg-white items-center justify-center z-20">
            <RefreshCw size={48} color="#94a3b8" />
            <Text className="text-slate-600 font-medium mt-4 text-lg">Bağlantı Hatası</Text>
            <TouchableOpacity
              onPress={handleReload}
              className="mt-6 bg-[#5b50f7] px-6 py-3 rounded-full"
            >
              <Text className="text-white font-bold">Tekrar Dene</Text>
            </TouchableOpacity>
          </View>
        )}
      </View>

      {/* Bottom Tab Bar */}
      {shouldShowTabBar && (
        <View className="flex-row items-end justify-between bg-white border-t border-slate-100 pb-2 h-[75px] px-2 shadow-[0_-5px_10px_rgba(0,0,0,0.02)]">
          <TabItem
            icon={Home}
            label="Anasayfa"
            targetUrl={URLs.home}
            isActive={currentUrl.includes('/home') || currentUrl === URLs.base}
          />
          <TabItem
            icon={Search}
            label="Görev Bul"
            targetUrl={URLs.dashboard}
            isActive={currentUrl.includes('/dashboard')}
          />

          {/* Center Floating Button */}
          <View className="w-20 items-center z-50">
            <TabItem
              icon={PlusCircle}
              targetUrl={URLs.create}
              isActive={currentUrl.includes('/create-job')}
              isFloating={true}
            />
          </View>

          <TabItem
            icon={Briefcase}
            label="Görevlerim"
            targetUrl={URLs.myJobs}
            isActive={currentUrl.includes('/my-jobs')}
          />
          <TabItem
            icon={User}
            label="Profil"
            targetUrl={URLs.profile}
            isActive={currentUrl.includes('/profile')}
          />
        </View>
      )}
    </SafeAreaView>
  );
}
