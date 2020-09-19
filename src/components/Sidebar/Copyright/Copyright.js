// @flow strict
import React from 'react';
import styles from './Copyright.module.scss';

type Props = {
  copyright: string
};

const Copyright = ({ copyright }: Props) => (
  <div>
    <div className={styles['copyright']}>
  <iframe src="https://bkrm.substack.com/embed" width="290" height="250" styles="border:1px solid #EEE; background:white;" frameborder="0" scrolling="no"></iframe>
  </div>
  <div className={styles['copyright']}>
    {copyright}
  </div>
  </div>
);

export default Copyright;
