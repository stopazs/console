import * as rest from "../util/rest";

export const updateOrganizationHotspot = (hotspot_address, claimed) => {
  return rest
    .post(`/api/organization_hotspot`, {
      hotspot_address,
      claimed,
    })
    .then((res) => res.status);
};

export const updateHotspotAlias = (hotspot_address, alias) => {
  return rest
    .post(`/api/organization_hotspot`, {
      hotspot_address,
      alias,
    })
    .then((res) => res.status);
};

export const updateOrganizationHotspots = (hotspot_addresses, claimed) => {
  return rest
    .post(`/api/organization_hotspots`, {
      hotspot_addresses,
      claimed,
    })
    .then((res) => res.status);
};
