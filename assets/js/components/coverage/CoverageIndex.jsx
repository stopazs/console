import React, { useEffect } from "react";
import DashboardLayout from "../common/DashboardLayout";
import Mapbox from "../common/Mapbox";
import CoverageMainTab from "./CoverageMainTab"
import CoverageFollowedTab from "./CoverageFollowedTab"
import CoverageSearchTab from "./CoverageSearchTab"
import { Typography, Tabs, Row, Col } from "antd";
import analyticsLogger from "../../util/analyticsLogger";
const { Text } = Typography;
const { TabPane } = Tabs;

export default (props) => {
  // useEffect(() => {
  //   analyticsLogger.logEvent("ACTION_NAV_COVERAGE_INDEX");
  // }, []);
  return (
    <DashboardLayout title="Coverage" user={props.user} noAddButton>
      <div
        style={{
          height: "100%",
          width: "100%",
          backgroundColor: "#ffffff",
          borderRadius: 6,
          overflow: "hidden",
          boxShadow: "0px 20px 20px -7px rgba(17, 24, 31, 0.19)",
        }}
      >
        <Row>
          <Col sm={14}>
            <Tabs
              defaultActiveKey="main"
              size="large"
              tabBarStyle={{ paddingLeft: 20, paddingRight: 20, height: 40, marginTop: 20 }}
            >
              <TabPane tab="Coverage Breakdown" key="main">
                <CoverageMainTab />
              </TabPane>
              <TabPane tab="My Hotspots" key="followed">
                <CoverageFollowedTab />
              </TabPane>
              <TabPane tab="Hotspot Search" key="search">
                <CoverageSearchTab />
              </TabPane>
            </Tabs>
          </Col>
          <Col sm={10}>
            <Mapbox />
          </Col>
        </Row>
      </div>
    </DashboardLayout>
  );
};