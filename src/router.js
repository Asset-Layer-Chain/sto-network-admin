import { useEffect, useState } from 'react';

function getLocation() {
  return {
    pathname: window.location.pathname || '/',
    search: window.location.search || '',
  };
}

export function navigate(path, { replace = false } = {}) {
  if (replace) window.history.replaceState({}, '', path);
  else window.history.pushState({}, '', path);
  window.dispatchEvent(new PopStateEvent('popstate'));
}

export function useLocation() {
  const [location, setLocation] = useState(getLocation);

  useEffect(() => {
    const onChange = () => setLocation(getLocation());
    window.addEventListener('popstate', onChange);
    return () => window.removeEventListener('popstate', onChange);
  }, []);

  return location;
}
